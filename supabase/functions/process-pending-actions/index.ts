// verify_jwt=false — worker class (see supabase/config.toml +
// EDGE_FUNCTION_AUTH_MATRIX.md "Worker"). docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md
// #6 "process-pending-actions: confirmed only, lease/reclaim,
// reauthorization, DB/external side effect recovery."
//
// This is a *separate* execution queue from process-line-inbox's own inbox
// draining (01_ARCHITECTURE.md draws two distinct arrows: webhook_inbox ->
// process-line-inbox, and pending_actions -> process-pending-actions).
// process-line-inbox only ever writes 'draft' pending_actions and flips
// draft->confirmed/cancelled on postback; this worker claims 'confirmed'
// rows (private.mutation_receipts-backed lease/reclaim/dead-letter — same
// mechanics as process-line-inbox's webhook_inbox queue, see
// 20260819000042) and performs the actual business mutation.
//
// "Reauthorization": every execution re-derives the household via
// public.household_members inside the target server_tx_* mutation itself
// (each mutation function does its own `select household_id from
// household_members where user_id = p_actor_id` before acting) — so if the
// actor left the household or was removed between confirm and execution,
// the mutation's own NOT_HOUSEHOLD_MEMBER/CROSS_HOUSEHOLD_RESOURCE checks
// reject it at execution time, not just at staging time.
//
// Only executes action_types this worker knows how to turn into a
// server_tx_* mutation call (currently: shopping_item_add, task_create_once
// — the same deterministic subset process-line-inbox's parser produces).
// An unrecognized action_type is treated as an execution failure (goes
// through the normal fail/retry/dead-letter path below) rather than being
// silently skipped, so a bad action_type doesn't jam the queue forever.
import { createServiceRoleClient, requireWorkerToken } from "../_shared/auth.ts";
import { withServiceHandler, jsonResponse } from "../_shared/handler.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

const WORKER_ID = `process-pending-actions:${crypto.randomUUID()}`;
const BATCH_LIMIT = Number(Deno.env.get("PENDING_ACTIONS_BATCH_LIMIT") ?? "25");
const LEASE_SECONDS = Number(Deno.env.get("PENDING_ACTIONS_LEASE_SECONDS") ?? "55");
const MAX_ATTEMPTS = Number(Deno.env.get("PENDING_ACTIONS_MAX_ATTEMPTS") ?? "5");
const RETRY_DELAY_SECONDS = Number(Deno.env.get("PENDING_ACTIONS_RETRY_DELAY_SECONDS") ?? "30");

interface PendingActionItem {
  id: string;
  household_id: string;
  actor_id: string;
  action_type: string;
  normalized_payload: Record<string, unknown>;
  operation_id: string;
  attempts: number;
  lease_token: string;
}

interface ExecutionOutcome {
  result_type: string;
  result_id: string | null;
}

async function execute(client: SupabaseClient, item: PendingActionItem): Promise<ExecutionOutcome> {
  const p = item.normalized_payload;

  switch (item.action_type) {
    case "shopping_item_add": {
      const { data, error } = await client.rpc("server_tx_add_shopping_item", {
        p_actor_id: item.actor_id,
        p_operation_id: item.operation_id,
        p_title: String(p.title ?? ""),
        p_purchase_method: String(p.purchase_method ?? "store"),
        p_assignee_user_id: p.assignee_user_id ?? null,
        p_url: p.url ?? null,
        p_due_at: p.due_at ?? null,
      });
      if (error) throw new Error(error.message);
      return { result_type: "shopping_item", result_id: (data as { shopping_item_id?: string })?.shopping_item_id ?? null };
    }
    case "task_create_once": {
      const { data, error } = await client.rpc("server_tx_create_task", {
        p_actor_id: item.actor_id,
        p_operation_id: item.operation_id,
        p_title: String(p.title ?? ""),
        p_category: p.category ?? "todo",
        p_scheduled_date: p.scheduled_date,
        p_due_local_time: p.due_local_time ?? null,
        p_planned_assignee_user_id: p.planned_assignee_user_id ?? null,
        p_completion_mode: "whole",
        p_routine_phase: p.routine_phase ?? "anytime",
        p_subtasks: null,
      });
      if (error) throw new Error(error.message);
      return { result_type: "task", result_id: (data as { task_id?: string })?.task_id ?? null };
    }
    default:
      throw new Error(`unsupported action_type: ${item.action_type}`);
  }
}

Deno.serve(withServiceHandler(async (req: Request) => {
  requireWorkerToken(req); // throws EDGE_WORKER_UNAUTHORIZED before any DB access

  const client = createServiceRoleClient();

  const { data: batchData, error: claimError } = await client.rpc("server_tx_claim_pending_actions_batch", {
    p_worker_id: WORKER_ID,
    p_limit: BATCH_LIMIT,
    p_lease_seconds: LEASE_SECONDS,
  });
  if (claimError) {
    console.error("process-pending-actions: claim batch failed", claimError.message);
    return new Response(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "internal error" } }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const items = (batchData ?? []) as PendingActionItem[];
  let succeeded = 0;
  let failed = 0;

  for (const item of items) {
    try {
      const outcome = await execute(client, item);
      const { data: completeData } = await client.rpc("server_tx_complete_pending_action", {
        p_id: item.id,
        p_lease_token: item.lease_token,
        p_result_type: outcome.result_type,
        p_result_id: outcome.result_id,
      });
      if ((completeData as { ok?: boolean } | null)?.ok) succeeded++;
    } catch (err) {
      failed++;
      const message = err instanceof Error ? err.message : String(err);
      console.error("process-pending-actions: item execution failed", { id: item.id, message });
      await client.rpc("server_tx_fail_pending_action", {
        p_id: item.id,
        p_lease_token: item.lease_token,
        p_error: message.slice(0, 500),
        p_max_attempts: MAX_ATTEMPTS,
        p_retry_delay_seconds: RETRY_DELAY_SECONDS,
      });
    }
  }

  return jsonResponse({ claimed: items.length, succeeded, failed });
}));

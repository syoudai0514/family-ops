// verify_jwt=false — worker class. Confirmed LINE/PWA pending actions are
// executed here, never inline in the sender's confirmation postback.
import { createServiceRoleClient, requireWorkerToken } from '../_shared/auth.ts';
import { withServiceHandler, jsonResponse } from '../_shared/handler.ts';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

const WORKER_ID = `process-pending-actions:${crypto.randomUUID()}`;
const BATCH_LIMIT = Number(Deno.env.get('PENDING_ACTIONS_BATCH_LIMIT') ?? '25');
const LEASE_SECONDS = Number(Deno.env.get('PENDING_ACTIONS_LEASE_SECONDS') ?? '55');
const MAX_ATTEMPTS = Number(Deno.env.get('PENDING_ACTIONS_MAX_ATTEMPTS') ?? '5');
const RETRY_DELAY_SECONDS = Number(Deno.env.get('PENDING_ACTIONS_RETRY_DELAY_SECONDS') ?? '30');

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

function requestDueAt(payload: Record<string, unknown>): string | null {
  const date = typeof payload.scheduled_date === 'string' ? payload.scheduled_date : null;
  if (!date) return null;
  const localTime = typeof payload.due_local_time === 'string' && /^\d{2}:\d{2}$/.test(payload.due_local_time)
    ? payload.due_local_time
    : '23:59';
  const value = new Date(`${date}T${localTime}:00+09:00`);
  return Number.isNaN(value.getTime()) ? null : value.toISOString();
}

async function execute(client: SupabaseClient, item: PendingActionItem): Promise<ExecutionOutcome> {
  const p = item.normalized_payload;

  switch (item.action_type) {
    case 'shopping_item_add': {
      const { data, error } = await client.rpc('server_tx_add_shopping_item', {
        p_actor_id: item.actor_id,
        p_operation_id: item.operation_id,
        p_title: String(p.title ?? ''),
        p_purchase_method: String(p.purchase_method ?? 'store'),
        p_assignee_user_id: p.assignee_user_id ?? null,
        p_url: p.url ?? null,
        p_due_at: p.due_at ?? null,
      });
      if (error) throw new Error(error.message);
      return {
        result_type: 'shopping_item',
        result_id: (data as { shopping_item_id?: string })?.shopping_item_id ?? null,
      };
    }
    case 'task_create_once': {
      const { data, error } = await client.rpc('server_tx_create_task', {
        p_actor_id: item.actor_id,
        p_operation_id: item.operation_id,
        p_title: String(p.title ?? ''),
        p_category: p.category ?? 'todo',
        p_scheduled_date: p.scheduled_date,
        p_due_local_time: p.due_local_time ?? null,
        p_planned_assignee_user_id: p.planned_assignee_user_id ?? null,
        p_completion_mode: 'whole',
        p_routine_phase: p.routine_phase ?? 'anytime',
        p_subtasks: null,
      });
      if (error) throw new Error(error.message);
      return { result_type: 'task', result_id: (data as { task_id?: string })?.task_id ?? null };
    }
    case 'request_create': {
      const recipient = typeof p.recipient_user_id === 'string' ? p.recipient_user_id : '';
      if (!recipient) throw new Error('request_create missing recipient_user_id');
      const { data, error } = await client.rpc('server_tx_send_request', {
        p_actor_id: item.actor_id,
        p_operation_id: item.operation_id,
        p_recipient_user_id: recipient,
        p_shared_title: String(p.title ?? ''),
        p_shared_message: typeof p.shared_message === 'string' ? p.shared_message : null,
        p_due_at: requestDueAt(p),
      });
      if (error) throw new Error(error.message);
      return {
        result_type: 'request',
        result_id: (data as { request_id?: string })?.request_id ?? null,
      };
    }
    case 'request_accept': {
      const requestId = typeof p.request_id === 'string' ? p.request_id : '';
      if (!requestId) throw new Error('request_accept missing request_id');
      const { data, error } = await client.rpc('server_tx_accept_request', {
        p_actor_id: item.actor_id,
        p_operation_id: item.operation_id,
        p_request_id: requestId,
      });
      if (error) {
        if (/REQUEST_(?:NOT_PENDING|ACCEPT_NOT_ALLOWED)/.test(error.message)) {
          return { result_type: 'request', result_id: requestId };
        }
        throw new Error(error.message);
      }
      return {
        result_type: 'task',
        result_id: (data as { task_id?: string })?.task_id ?? null,
      };
    }
    case 'request_decline': {
      const requestId = typeof p.request_id === 'string' ? p.request_id : '';
      if (!requestId) throw new Error('request_decline missing request_id');
      const { data, error } = await client.rpc('server_tx_decline_request', {
        p_actor_id: item.actor_id,
        p_operation_id: item.operation_id,
        p_request_id: requestId,
      });
      if (error) {
        if (/REQUEST_(?:NOT_PENDING|DECLINE_NOT_ALLOWED)/.test(error.message)) {
          return { result_type: 'request', result_id: requestId };
        }
        throw new Error(error.message);
      }
      return {
        result_type: 'request',
        result_id: (data as { request_id?: string })?.request_id ?? requestId,
      };
    }
    case 'assignment_change_request': {
      const { data, error } = await client.rpc('server_tx_create_assignment_change_request', {
        p_actor_id: item.actor_id,
        p_operation_id: item.operation_id,
        p_task_id: p.task_id,
        p_recipient_user_id: p.recipient_user_id,
        p_shared_message: p.shared_message ?? null,
        p_scope: p.scope ?? 'once',
      });
      if (error) throw new Error(error.message);
      return {
        result_type: 'request',
        result_id: (data as { request_id?: string })?.request_id ?? null,
      };
    }
    default:
      throw new Error(`unsupported action_type: ${item.action_type}`);
  }
}

Deno.serve(
  withServiceHandler(async (req: Request) => {
    requireWorkerToken(req);
    const client = createServiceRoleClient();

    const { data: batchData, error: claimError } = await client.rpc(
      'server_tx_claim_pending_actions_batch',
      {
        p_worker_id: WORKER_ID,
        p_limit: BATCH_LIMIT,
        p_lease_seconds: LEASE_SECONDS,
      },
    );
    if (claimError) {
      console.error('process-pending-actions: claim batch failed', claimError.message);
      return new Response(
        JSON.stringify({ error: { code: 'INTERNAL_ERROR', message: 'internal error' } }),
        { status: 500, headers: { 'Content-Type': 'application/json' } },
      );
    }

    const items = (batchData ?? []) as PendingActionItem[];
    let succeeded = 0;
    let failed = 0;

    for (const item of items) {
      try {
        const outcome = await execute(client, item);
        const { data: completeData } = await client.rpc('server_tx_complete_pending_action', {
          p_id: item.id,
          p_lease_token: item.lease_token,
          p_result_type: outcome.result_type,
          p_result_id: outcome.result_id,
        });
        if ((completeData as { ok?: boolean } | null)?.ok) succeeded++;
      } catch (err) {
        failed++;
        const message = err instanceof Error ? err.message : String(err);
        console.error('process-pending-actions: item processing failed', { id: item.id, message });
        await client.rpc('server_tx_fail_pending_action', {
          p_id: item.id,
          p_lease_token: item.lease_token,
          p_error: message.slice(0, 500),
          p_max_attempts: MAX_ATTEMPTS,
          p_retry_delay_seconds: RETRY_DELAY_SECONDS,
        });
      }
    }

    return jsonResponse({ claimed: items.length, succeeded, failed });
  }),
);

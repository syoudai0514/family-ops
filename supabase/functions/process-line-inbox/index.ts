// verify_jwt=false — worker class (see supabase/config.toml +
// EDGE_FUNCTION_AUTH_MATRIX.md "Worker"). docs/design/v6/06_LINE_INTEGRATION.md
// #3 "Worker process-line-inbox every 1 min handles parse/action."
//
// Scope (WP6): drains private.webhook_inbox (lease/reclaim/dead-letter via
// server_tx_claim/complete/fail_webhook_inbox_*, 20260819000041), resolves
// the sending LINE user to a Family Ops actor via
// private.line_user_links (server_tx_resolve_line_actor), and turns each
// event into one of:
//   - a link-token claim (an unauthenticated text message whose body is
//     exactly a pasted link token — the one path that runs before an actor
//     exists; #2 "verified LINE webhook source.userIdを取得")
//   - a postback: pending-action confirm/cancel (#9 "Confirmation postback
//     itself never performs external side-effect inline; it marks confirmed
//     then worker executes"), or a low-risk deterministic direct-execute
//     mutation (#9 "Routine 完了 postbacks may call user mutation Edge
//     directly because the action/resource is explicit and standard
//     idempotency applies") — here, task completion.
//   - free text: the small deterministic grammar in ./parser.ts. Anything
//     outside that grammar becomes a 'draft' pending_action
//     (action_type='needs_pwa_review') for PWA follow-up — never
//     auto-confirmed (#9 "must preview first").
//
// Every action this worker takes on behalf of an already-linked user derives
// its mutation operation_id deterministically from the LINE webhook event's
// own provider_event_id (see deterministicOperationId below), so redelivery
// of the same event — whether LINE's own retry or this worker reclaiming a
// stale lease after a crash — always replays the same
// private.mutation_receipts / private.pending_actions row instead of
// double-executing (#13 "duplicate webhook -> one mutation"; #14 "user taps
// same postback twice -> mutation receipt replay").
//
// Routine-session checklist automation (dispatch-routine-automation,
// get-routine-session/complete-routine-session/routine-session-item-action)
// is WP8. Its RPCs are called directly here too (docs/design/v6/
// 17_ROUTINE_LINE_AUTOMATION.md #8 "Routine 完了 postbacks may call user
// mutation Edge directly"; #9 "LINEとPWAは同じmutation APIを使う") — see
// docs/adr/0007 decision 1, which this closes:
//   action=routine_item&session_id=...&task_instance_id=...&value=complete|partner_handled|skip
//   action=routine_complete&session_id=...&value=complete_all|skip_incomplete
// p_source is always 'line' for both, so task_events / mutation results
// correctly attribute the channel per #9.
import { createServiceRoleClient, requireWorkerToken } from "../_shared/auth.ts";
import { withServiceHandler, jsonResponse } from "../_shared/handler.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { parseLineText } from "./parser.ts";

const WORKER_ID = `process-line-inbox:${crypto.randomUUID()}`;
const BATCH_LIMIT = Number(Deno.env.get("LINE_INBOX_BATCH_LIMIT") ?? "25");
const LEASE_SECONDS = Number(Deno.env.get("LINE_INBOX_LEASE_SECONDS") ?? "55");
const MAX_ATTEMPTS = Number(Deno.env.get("LINE_INBOX_MAX_ATTEMPTS") ?? "5");
const RETRY_DELAY_SECONDS = Number(Deno.env.get("LINE_INBOX_RETRY_DELAY_SECONDS") ?? "30");
const PENDING_ACTION_TTL_MINUTES = Number(Deno.env.get("LINE_PENDING_ACTION_TTL_MINUTES") ?? "30");

// A raw link token is always exactly 64 hex chars (two concatenated UUIDs —
// see server_tx_create_line_link_token). Anything else is not a link-token
// attempt.
const LINK_TOKEN_RE = /^[0-9a-f]{64}$/i;

interface LineActor {
  user_id: string;
  household_id: string;
}

interface WebhookInboxItem {
  id: string;
  provider_event_id: string;
  source_external_user_id: string | null;
  payload: {
    type?: string;
    message?: { type?: string; text?: string };
    postback?: { data?: string };
  };
  attempts: number;
  lease_token: string;
}

// Deterministic, event-scoped UUID (v4-shaped, but content-derived rather
// than random) so redelivery/lease-reclaim of the same LINE webhook event
// always maps to the same operation_id — private.pending_actions
// (unique(actor_id, operation_id)) and private.mutation_receipts
// (actor_id, operation_id) both dedupe on it, giving exactly-once effect
// regardless of how many times this event is processed.
async function deterministicOperationId(...parts: string[]): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(parts.join("|"))),
  );
  const hex = Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    "4" + hex.slice(13, 16),
    ((parseInt(hex.slice(16, 18), 16) & 0x3f) | 0x80).toString(16).padStart(2, "0") + hex.slice(18, 20),
    hex.slice(20, 32),
  ].join("-");
}

function parsePostbackData(data: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of new URLSearchParams(data).entries()) out[key] = value;
  return out;
}

async function resolveActor(client: SupabaseClient, lineUserId: string | null): Promise<LineActor | null> {
  if (!lineUserId) return null;
  const { data, error } = await client.rpc("server_tx_resolve_line_actor", {
    p_source_external_user_id: lineUserId,
  });
  if (error) {
    console.error("process-line-inbox: resolve actor failed", error.message);
    return null;
  }
  return (data as LineActor | null) ?? null;
}

async function tryClaimLinkToken(
  client: SupabaseClient,
  sourceExternalUserId: string | null,
  text: string,
): Promise<boolean> {
  const trimmed = text.trim();
  if (!LINK_TOKEN_RE.test(trimmed) || !sourceExternalUserId) return false;

  const { error } = await client.rpc("server_tx_claim_line_link_token", {
    p_source_external_user_id: sourceExternalUserId,
    p_raw_token: trimmed,
  });
  if (error) {
    // Expired/used/already-linked/unknown-token are all expected user
    // errors here (mistyped or stale token) — logged for observability,
    // never thrown (there is no reply channel back to the user from this
    // batch worker; the PWA link screen is the retry path).
    console.warn("process-line-inbox: link token claim rejected", error.message);
  }
  return true; // handled either way — never falls through to command parsing
}

async function handlePostback(client: SupabaseClient, item: WebhookInboxItem, actor: LineActor | null): Promise<void> {
  const data = item.payload.postback?.data;
  if (!data || !actor) return;
  const fields = parsePostbackData(data);

  if (fields.action === "confirm_pending" && fields.pending_action_id) {
    const { error } = await client.rpc("server_tx_confirm_pending_action", {
      p_actor_id: actor.user_id,
      p_pending_action_id: fields.pending_action_id,
    });
    if (error) console.error("process-line-inbox: confirm_pending failed", error.message);
    return;
  }

  if (fields.action === "cancel_pending" && fields.pending_action_id) {
    const { error } = await client.rpc("server_tx_cancel_pending_action", {
      p_actor_id: actor.user_id,
      p_pending_action_id: fields.pending_action_id,
    });
    if (error) console.error("process-line-inbox: cancel_pending failed", error.message);
    return;
  }

  if (fields.action === "complete_task" && fields.task_id) {
    // #9's low-risk deterministic-completion exception: calls the normal
    // mutation contract directly rather than staging a pending_action.
    const operationId = await deterministicOperationId("line-postback", item.provider_event_id);
    const completionActor = fields.completion_actor === "partner" ? "partner" : "self";
    const { error } = await client.rpc("server_tx_complete_task", {
      p_actor_id: actor.user_id,
      p_operation_id: operationId,
      p_task_id: fields.task_id,
      p_completion_actor: completionActor,
      p_complete_remaining_subtasks: fields.complete_remaining === "true",
    });
    if (error) console.error("process-line-inbox: complete_task postback failed", error.message);
    return;
  }

  if (fields.action === "routine_item" && fields.session_id && fields.task_instance_id && fields.value) {
    if (!["complete", "partner_handled", "skip"].includes(fields.value)) {
      console.warn("process-line-inbox: invalid routine_item value", { value: fields.value });
      return;
    }
    const operationId = await deterministicOperationId("line-postback", item.provider_event_id);
    const { error } = await client.rpc("server_tx_routine_session_item_action", {
      p_actor_id: actor.user_id,
      p_operation_id: operationId,
      p_session_id: fields.session_id,
      p_task_instance_id: fields.task_instance_id,
      p_action: fields.value,
      p_source: "line",
    });
    if (error) console.error("process-line-inbox: routine_item postback failed", error.message);
    return;
  }

  if (fields.action === "routine_complete" && fields.session_id && fields.value) {
    if (!["complete_all", "skip_incomplete"].includes(fields.value)) {
      console.warn("process-line-inbox: invalid routine_complete value", { value: fields.value });
      return;
    }
    const operationId = await deterministicOperationId("line-postback", item.provider_event_id);
    const { error } = await client.rpc("server_tx_complete_routine_session", {
      p_actor_id: actor.user_id,
      p_operation_id: operationId,
      p_session_id: fields.session_id,
      p_disposition: fields.value,
      p_source: "line",
    });
    if (error) console.error("process-line-inbox: routine_complete postback failed", error.message);
    return;
  }

  console.warn("process-line-inbox: unrecognized postback action", { action: fields.action ?? null });
}

async function handleText(
  client: SupabaseClient,
  item: WebhookInboxItem,
  actor: LineActor | null,
  text: string,
): Promise<void> {
  if (await tryClaimLinkToken(client, item.source_external_user_id, text)) return;
  if (!actor) return; // unlinked sender; nothing else can be safely attributed

  const parsed = parseLineText(text);
  const operationId = await deterministicOperationId("line-text", item.provider_event_id);

  const { error } = await client.rpc("server_tx_create_pending_action", {
    p_actor_id: actor.user_id,
    p_household_id: actor.household_id,
    p_operation_id: operationId,
    p_source: "line",
    p_action_type: parsed?.actionType ?? "needs_pwa_review",
    p_normalized_payload: parsed?.payload ?? { raw_text: text },
    p_ttl_minutes: PENDING_ACTION_TTL_MINUTES,
  });
  if (error) console.error("process-line-inbox: create_pending_action failed", error.message);
}

async function processItem(client: SupabaseClient, item: WebhookInboxItem): Promise<void> {
  const actor = await resolveActor(client, item.source_external_user_id);

  if (item.payload.type === "postback") {
    await handlePostback(client, item, actor);
  } else if (item.payload.type === "message" && item.payload.message?.type === "text") {
    await handleText(client, item, actor, item.payload.message.text ?? "");
  }
  // Other event types (follow/unfollow/join/beacon/etc.) are durably stored
  // but have no v6-documented action — acknowledged as done, no side effect.
}

Deno.serve(withServiceHandler(async (req: Request) => {
  requireWorkerToken(req); // throws EDGE_WORKER_UNAUTHORIZED before any DB access

  const client = createServiceRoleClient();

  const { data: batchData, error: claimError } = await client.rpc("server_tx_claim_webhook_inbox_batch", {
    p_worker_id: WORKER_ID,
    p_limit: BATCH_LIMIT,
    p_lease_seconds: LEASE_SECONDS,
  });
  if (claimError) {
    console.error("process-line-inbox: claim batch failed", claimError.message);
    return new Response(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "internal error" } }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const items = (batchData ?? []) as WebhookInboxItem[];
  let succeeded = 0;
  let failed = 0;

  for (const item of items) {
    try {
      await processItem(client, item);
      const { data: completeData } = await client.rpc("server_tx_complete_webhook_inbox_item", {
        p_id: item.id,
        p_lease_token: item.lease_token,
      });
      if ((completeData as { ok?: boolean } | null)?.ok) succeeded++;
    } catch (err) {
      failed++;
      const message = err instanceof Error ? err.message : String(err);
      console.error("process-line-inbox: item processing failed", { id: item.id, message });
      await client.rpc("server_tx_fail_webhook_inbox_item", {
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

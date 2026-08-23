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
//
// P1-4 (review fix, docs/adr/0009): after any successful postback/text RPC
// call above, sendConfirmation() sends a short reply-first confirmation via
// ../_shared/lineMessaging.ts -- LINE Reply API first (free, no quota),
// falling back to a durable push-outbox row only when the reply is
// unavailable/fails (#10A "Reply").
//
// Re-review fix (P1-1/P1-2, docs/adr/0010): two more postback flows close
// the gap the second independent review found -- #8's LINE-native
// "項目ごとに入力" state machine (routine_item_mode / routine_item_next,
// backed by routineItemFlow.ts's pure selection logic; the existing
// routine_item postback above now also chains into "show the next
// unfinished item" after a successful mutation) and the mandatory
// confirmation step before a top-level "今回は不要" mass-skip
// (routine_skip_prompt / routine_cancel_prompt -- NEITHER mutates; only the
// existing routine_complete&value=skip_incomplete branch, reached after an
// explicit confirm tap, still calls server_tx_complete_routine_session).
import { createServiceRoleClient, requireWorkerToken } from '../_shared/auth.ts';
import { withServiceHandler, jsonResponse } from '../_shared/handler.ts';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { parseLineText } from './parser.ts';
import { extractLineIntent, daypartLabel, daypartToLocalTime } from './lineIntent.ts';
import { replyOrEnqueuePush } from '../_shared/lineMessaging.ts';
import type { LineQuickReplyAction } from '../_shared/lineMessaging.ts';
import {
  buildItemPromptText,
  buildItemQuickReply,
  buildStaleSessionText,
  pickNextUnfinished,
  type RoutineSessionItem,
} from './routineItemFlow.ts';
import {
  buildAssignmentSenderPreviewFlex,
  buildPendingActionPreviewFlex,
  rewritePickupRequest,
} from '../_shared/lineMessageBuilders.ts';
import { resolveJapanesePickupDate } from '../_shared/pickupDate.ts';
import { missingRoleQuickReplies, missingRoleRecoveryText } from './linePartnerInviteFlow.ts';
import {
  completionHint,
  formatScheduleReply,
  menuQuickReplies,
  readOnlyLineIntent,
  type CompactScheduleEntry,
} from './lineConversation.ts';

const WORKER_ID = `process-line-inbox:${crypto.randomUUID()}`;
const BATCH_LIMIT = Number(Deno.env.get('LINE_INBOX_BATCH_LIMIT') ?? '25');
const LEASE_SECONDS = Number(Deno.env.get('LINE_INBOX_LEASE_SECONDS') ?? '55');
const MAX_ATTEMPTS = Number(Deno.env.get('LINE_INBOX_MAX_ATTEMPTS') ?? '5');
const RETRY_DELAY_SECONDS = Number(Deno.env.get('LINE_INBOX_RETRY_DELAY_SECONDS') ?? '30');
const PENDING_ACTION_TTL_MINUTES = Number(Deno.env.get('LINE_PENDING_ACTION_TTL_MINUTES') ?? '30');

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
    // LINE's own event objects carry this for message/postback events
    // (docs/design/v6/06_LINE_INTEGRATION.md #10A "Reply"; P1-4 fix). No
    // schema change needed -- private.webhook_inbox.payload already stores
    // the whole raw webhook event verbatim (line-webhook-receiver). Never
    // logged in full; only passed through to replyOrEnqueuePush.
    replyToken?: string;
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
    await crypto.subtle.digest('SHA-256', new TextEncoder().encode(parts.join('|'))),
  );
  const hex = Array.from(digest, (b) => b.toString(16).padStart(2, '0')).join('');
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    '4' + hex.slice(13, 16),
    ((parseInt(hex.slice(16, 18), 16) & 0x3f) | 0x80).toString(16).padStart(2, '0') +
      hex.slice(18, 20),
    hex.slice(20, 32),
  ].join('-');
}

function parsePostbackData(data: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of new URLSearchParams(data).entries()) out[key] = value;
  return out;
}

async function resolveActor(
  client: SupabaseClient,
  lineUserId: string | null,
): Promise<LineActor | null> {
  if (!lineUserId) return null;
  const { data, error } = await client.rpc('server_tx_resolve_line_actor', {
    p_source_external_user_id: lineUserId,
  });
  if (error) {
    console.error('process-line-inbox: resolve actor failed', error.message);
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

  const { error } = await client.rpc('server_tx_claim_line_link_token', {
    p_source_external_user_id: sourceExternalUserId,
    p_raw_token: trimmed,
  });
  if (error) {
    // Expired/used/already-linked/unknown-token are all expected user
    // errors here (mistyped or stale token) — logged for observability,
    // never thrown (there is no reply channel back to the user from this
    // batch worker; the PWA link screen is the retry path).
    console.warn('process-line-inbox: link token claim rejected', error.message);
  }
  return true; // handled either way — never falls through to command parsing
}

// P1-4 fix: a short confirmation for a webhook-triggered interaction this
// worker just handled, sent reply-first (free, no quota) with an immediate
// push-outbox fallback (see ../_shared/lineMessaging.ts). Best-effort by
// design -- the underlying mutation already happened and is idempotent via
// deterministicOperationId; a lost/duplicated confirmation is a minor UX
// gap, never a correctness issue (docs/design/v6/06_LINE_INTEGRATION.md
// #10A "Reply", #12 "Reply vs push").
async function sendConfirmation(
  client: SupabaseClient,
  item: WebhookInboxItem,
  actor: LineActor,
  text: string,
  quickReplyItems?: LineQuickReplyAction[],
): Promise<void> {
  const result = await replyOrEnqueuePush(client, {
    replyToken: item.payload.replyToken,
    lineUserId: item.source_external_user_id,
    householdId: actor.household_id,
    recipientUserId: actor.user_id,
    text,
    quickReplyItems,
    dedupKey: `line-reply-fallback:${item.provider_event_id}`,
  });
  if (result === 'no_channel') {
    console.warn('process-line-inbox: confirmation reply/push both unavailable', { id: item.id });
  }
}

function jstWeekRange(): { start: string; end: string } {
  const today = jstIsoDateOffset(0);
  const date = new Date(`${today}T00:00:00Z`);
  const day = date.getUTCDay();
  date.setUTCDate(date.getUTCDate() + (day === 0 ? -6 : 1 - day));
  const end = new Date(date);
  end.setUTCDate(end.getUTCDate() + 6);
  return { start: date.toISOString().slice(0, 10), end: end.toISOString().slice(0, 10) };
}

async function sendLineSchedule(
  client: SupabaseClient,
  item: WebhookInboxItem,
  actor: LineActor,
  kind: 'today' | 'tomorrow' | 'week',
): Promise<void> {
  const today = jstIsoDateOffset(0);
  const range =
    kind === 'week'
      ? jstWeekRange()
      : kind === 'tomorrow'
        ? { start: jstIsoDateOffset(1), end: jstIsoDateOffset(1) }
        : { start: today, end: today };
  const { data, error } =
    kind === 'today'
      ? await client.rpc('server_tx_get_today_schedule', { p_actor_id: actor.user_id })
      : await client.rpc('server_tx_get_week_schedule', {
          p_actor_id: actor.user_id,
          p_start_date: range.start,
          p_end_date: range.end,
        });
  if (error) {
    console.error('process-line-inbox: schedule read failed', error.message);
    await sendConfirmation(
      client,
      item,
      actor,
      '予定を読み込めませんでした。少し待ってからもう一度送ってください。',
      menuQuickReplies(),
    );
    return;
  }
  const { data: members } = await client
    .from('household_members')
    .select('user_id,family_role')
    .eq('household_id', actor.household_id);
  const roles = new Map<string, string>();
  for (const member of members ?? []) {
    if (member.family_role === 'papa') roles.set(member.user_id, 'P');
    if (member.family_role === 'mama') roles.set(member.user_id, 'M');
  }
  const schedule = (data ?? {}) as {
    assignments?: Array<{
      title?: string;
      due_at?: string | null;
      planned_assignee_id?: string | null;
      has_conflict?: boolean;
    }>;
    occurrences?: Array<{ title?: string; starts_at?: string | null }>;
  };
  const entries: CompactScheduleEntry[] = [
    ...(schedule.assignments ?? []).map((entry) => ({
      title: entry.title ?? 'タスク',
      startsAt: entry.due_at ?? null,
      roleLabel: entry.planned_assignee_id ? (roles.get(entry.planned_assignee_id) ?? null) : null,
      conflict: Boolean(entry.has_conflict),
    })),
    ...(schedule.occurrences ?? []).map((entry) => ({
      title: entry.title ?? 'Google Calendar予定',
      startsAt: entry.starts_at ?? null,
    })),
  ].sort((a, b) => (a.startsAt ?? '').localeCompare(b.startsAt ?? ''));
  const title = kind === 'today' ? '今日の予定' : kind === 'tomorrow' ? '明日の予定' : '今週の予定';
  await sendConfirmation(
    client,
    item,
    actor,
    formatScheduleReply(title, entries),
    menuQuickReplies(),
  );
}

async function tryHandleReadOnlyText(
  client: SupabaseClient,
  item: WebhookInboxItem,
  actor: LineActor,
  text: string,
): Promise<boolean> {
  const intent = readOnlyLineIntent(text);
  if (!intent) return false;
  if (intent === 'menu') {
    await sendConfirmation(
      client,
      item,
      actor,
      'おうちノートでできること\n\n文章でそのまま話しかけてOKです。\n・今日／明日／今週の予定\n・タスクを追加\n・お願いを送る\n・買い物を追加\n・朝／夜チェック',
      menuQuickReplies(),
    );
  } else {
    await sendLineSchedule(client, item, actor, intent);
  }
  return true;
}

// Re-review fix (P1-1): reads a session's current, live item state --
// server_tx_get_routine_session already reports items ordered by
// display_order and can_act (status='open' AND assignee_id=p_actor_id), the
// exact two things routine_item_mode/routine_item_next/routine_skip_prompt
// below need to decide "show the next item" vs. "resolve to the latest
// safe link" (docs/adr/0007 decision 2's existing pattern).
interface RoutineSessionRead {
  status: string;
  assignee_id: string;
  can_act: boolean;
  current_session_id: string | null;
  items: RoutineSessionItem[];
}

async function getRoutineSession(
  client: SupabaseClient,
  actorId: string,
  sessionId: string,
): Promise<RoutineSessionRead | null> {
  const { data, error } = await client.rpc('server_tx_get_routine_session', {
    p_actor_id: actorId,
    p_session_id: sessionId,
  });
  if (error) {
    console.error('process-line-inbox: get_routine_session failed', error.message);
    return null;
  }
  return data as RoutineSessionRead;
}

async function sendItemPrompt(
  client: SupabaseClient,
  item: WebhookInboxItem,
  actor: LineActor,
  sessionId: string,
  nextItem: RoutineSessionItem,
  prefixText?: string,
): Promise<void> {
  const text = prefixText
    ? `${prefixText}\n\n${buildItemPromptText(sessionId, nextItem)}`
    : buildItemPromptText(sessionId, nextItem);
  await sendConfirmation(
    client,
    item,
    actor,
    text,
    buildItemQuickReply(sessionId, nextItem.task_instance_id),
  );
}

async function sendStaleSessionReply(
  client: SupabaseClient,
  item: WebhookInboxItem,
  actor: LineActor,
  sessionId: string,
  currentSessionId: string | null,
): Promise<void> {
  await sendConfirmation(client, item, actor, buildStaleSessionText(currentSessionId, sessionId));
}

type EditablePendingAction = {
  id: string;
  action_type: string;
  normalized_payload: Record<string, unknown>;
  status: string;
};

function jstIsoDateOffset(offsetDays: number): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Tokyo',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date());
  const year = Number(parts.find((p) => p.type === 'year')?.value ?? '1970');
  const month = Number(parts.find((p) => p.type === 'month')?.value ?? '1');
  const day = Number(parts.find((p) => p.type === 'day')?.value ?? '1');
  const d = new Date(Date.UTC(year, month - 1, day + offsetDays));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
}

async function householdUserForRole(
  client: SupabaseClient,
  householdId: string,
  role: 'papa' | 'mama',
): Promise<string | null> {
  const { data } = await client
    .from('household_members')
    .select('user_id')
    .eq('household_id', householdId)
    .eq('family_role', role)
    .maybeSingle();
  return data?.user_id ?? null;
}

async function partnerUserId(client: SupabaseClient, actor: LineActor): Promise<string | null> {
  const { data } = await client
    .from('household_members')
    .select('user_id')
    .eq('household_id', actor.household_id)
    .neq('user_id', actor.user_id)
    .limit(1)
    .maybeSingle();
  return data?.user_id ?? null;
}

async function getEditablePending(
  client: SupabaseClient,
  actor: LineActor,
  id: string,
): Promise<EditablePendingAction | null> {
  const { data, error } = await client.rpc('server_tx_get_pending_action', {
    p_actor_id: actor.user_id,
    p_pending_action_id: id,
  });
  if (error) return null;
  return data as EditablePendingAction;
}

// A text correction is opt-in: it is only considered when the sender first
// tapped 編集 on that exact draft.  This prevents an unrelated later message
// such as "パパ帰る？" from changing a pending task.
async function getLineTextEditPending(
  client: SupabaseClient,
  actor: LineActor,
): Promise<EditablePendingAction | null> {
  const { data, error } = await client.rpc('server_tx_get_line_pending_text_edit', {
    p_actor_id: actor.user_id,
  });
  if (error || !data) return null;
  return data as EditablePendingAction;
}

function correctionRole(text: string): 'papa' | 'mama' | 'self' | null {
  // Prefer the replacement at the end of a contrast, otherwise accept an
  // explicit short correction such as "パパに変更".  "ママじゃなくてパパ"
  // therefore always means パパ.
  const contrast = text.match(
    /(?:パパ|父|お父さん|ママ|母|お母さん|嫁さん|奥さん|妻)\s*(?:じゃなくて|ではなくて|ではなく|じゃなく|の代わりに)\s*(パパ|父|お父さん|ママ|母|お母さん|嫁さん|奥さん|妻)/,
  );
  if (contrast) return /^(?:パパ|父|お父さん)$/.test(contrast[1]) ? 'papa' : 'mama';
  if (/(?:自分|自分に|自分へ)/.test(text)) return 'self';
  if (/(?:パパ|父|お父さん)/.test(text)) return 'papa';
  if (/(?:ママ|母|お母さん|嫁さん|奥さん|妻)/.test(text)) return 'mama';
  return null;
}

function correctionDate(text: string): string | null {
  if (/明後日/.test(text)) return jstIsoDateOffset(2);
  if (/明日/.test(text)) return jstIsoDateOffset(1);
  if (/今日|今夜|今朝/.test(text)) return jstIsoDateOffset(0);
  return null;
}

function correctionTime(text: string): string | null | undefined {
  if (/時刻なし|時間なし/.test(text)) return null;
  const explicit = text.match(/(?:午前|午後)?\s*(\d{1,2})時(?:\s*(\d{1,2})分?)?/);
  if (explicit) {
    let hour = Number(explicit[1]);
    const minute = Number(explicit[2] ?? '0');
    if (/午後/.test(text) && hour < 12) hour += 12;
    if (hour <= 23 && minute <= 59)
      return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
  }
  if (/朝/.test(text)) return '08:00';
  if (/夕方/.test(text)) return '18:00';
  if (/夜/.test(text)) return '20:00';
  return undefined;
}

function correctionTitle(text: string): string | null {
  const match = text
    .trim()
    .match(/^(?:タイトル|件名)\s*(?:は|を|:|：)\s*(.{1,80}?)(?:に変更|にして)?[。！!]?$/u);
  if (!match) return null;
  const title = match[1].replace(/\s+/g, ' ').trim();
  return title.length > 0 && title.length <= 80 ? title : null;
}

async function updateEditablePending(
  client: SupabaseClient,
  actor: LineActor,
  pendingActionId: string,
  actionType: string,
  payload: Record<string, unknown>,
): Promise<EditablePendingAction | null> {
  const { data, error } = await client.rpc('server_tx_update_pending_action', {
    p_actor_id: actor.user_id,
    p_pending_action_id: pendingActionId,
    p_action_type: actionType,
    p_normalized_payload: payload,
  });
  if (error) {
    console.error('process-line-inbox: update_pending failed', error.message);
    return null;
  }
  return data as EditablePendingAction;
}

async function sendMissingRoleRecovery(
  client: SupabaseClient,
  item: WebhookInboxItem,
  actor: LineActor,
  pendingActionId: string,
  role: 'papa' | 'mama',
): Promise<void> {
  const partner = await partnerUserId(client, actor);
  await sendConfirmation(
    client,
    item,
    actor,
    missingRoleRecoveryText(role, Boolean(partner)),
    partner ? editQuickReplies(pendingActionId) : missingRoleQuickReplies(pendingActionId),
  );
}

async function sendPartnerInviteLink(
  client: SupabaseClient,
  item: WebhookInboxItem,
  actor: LineActor,
  pendingActionId: string,
): Promise<void> {
  if (await partnerUserId(client, actor)) {
    await sendConfirmation(
      client,
      item,
      actor,
      'すでにパートナーは参加しています。もう一度「担当はママ」または「担当はパパ」と送ってください。',
    );
    return;
  }
  const operationId = await deterministicOperationId(
    'line-partner-invite',
    actor.user_id,
    pendingActionId,
  );
  const { data, error } = await client.rpc('server_tx_create_household_invite', {
    p_actor_id: actor.user_id,
    p_operation_id: operationId,
  });
  if (error || !data || typeof (data as { raw_token?: unknown }).raw_token !== 'string') {
    await sendConfirmation(
      client,
      item,
      actor,
      'この下書き用の招待リンクはすでに発行済みです。上の招待リンクをパートナーへ共有してください。下書きはそのまま残っています。',
    );
    return;
  }
  const base = (Deno.env.get('APP_BASE_URL') ?? '').replace(/\/$/, '');
  const url = base
    ? `${base}/join?token=${encodeURIComponent((data as { raw_token: string }).raw_token)}`
    : null;
  await sendConfirmation(
    client,
    item,
    actor,
    url
      ? `ママを招待するリンクです（24時間有効）。パートナーに共有してください。参加後、この下書きで「担当はママ」と送れば変更できます。\n${url}`
      : '招待リンクを作れませんでした。PWAの「設定 ＞ 家族」から招待してください。下書きはそのまま残っています。',
  );
}

async function tryApplyLineTextEdit(
  client: SupabaseClient,
  item: WebhookInboxItem,
  actor: LineActor,
  text: string,
): Promise<boolean> {
  const pending = await getLineTextEditPending(client, actor);
  if (!pending) return false;

  const role = correctionRole(text);
  const date = correctionDate(text);
  const time = correctionTime(text);
  const title = correctionTitle(text);
  if (!role && !date && time === undefined && !title) {
    await sendConfirmation(
      client,
      item,
      actor,
      '修正したい内容をそのまま送ってください。例:「ママじゃなくてパパ」「明日10時に変更」「時刻なし」。元の下書きはまだ変更していません。',
      editQuickReplies(pending.id),
    );
    return true;
  }

  let actionType = pending.action_type;
  const payload = { ...pending.normalized_payload };
  delete payload.line_edit_mode;
  if (title) payload.title = title;
  if (date) payload.scheduled_date = date;
  if (time !== undefined) {
    payload.due_local_time = time;
    payload.daypart = time === null ? null : (payload.daypart ?? null);
  }

  if (role) {
    const selected =
      role === 'self'
        ? actor.user_id
        : await householdUserForRole(client, actor.household_id, role);
    if (!selected) {
      // Only a requested family role can be absent; `self` always resolves to
      // the authenticated LINE actor.
      if (role === 'papa' || role === 'mama') {
        await sendMissingRoleRecovery(client, item, actor, pending.id, role);
      }
      return true;
    }
    const label = role === 'papa' ? 'パパ' : role === 'mama' ? 'ママ' : '自分';
    payload.target_label = label;
    if (actionType === 'shopping_item_add') {
      payload.assignee_user_id = selected;
    } else if (actionType === 'request_create' && selected !== actor.user_id) {
      payload.recipient_user_id = selected;
      delete payload.planned_assignee_user_id;
    } else {
      // Keep an explicitly chosen task as a task.  An existing request edited
      // back to oneself becomes a personal task instead of a request to self.
      actionType = 'task_create_once';
      payload.planned_assignee_user_id = selected;
      delete payload.recipient_user_id;
    }
  }

  const updated = await updateEditablePending(client, actor, pending.id, actionType, payload);
  if (!updated) {
    await sendConfirmation(
      client,
      item,
      actor,
      '修正を保存できませんでした。元の確認カードからもう一度お試しください。',
    );
    return true;
  }
  await sendPendingActionPreview(
    client,
    item,
    actor,
    updated.id,
    updated.action_type,
    updated.normalized_payload,
  );
  return true;
}

function targetLabel(payload: Record<string, unknown>, actor: LineActor): string {
  if (payload.target_label === 'パパ' || payload.target_label === 'ママ')
    return String(payload.target_label);
  if (payload.recipient_user_id) return 'パートナー';
  if (payload.planned_assignee_user_id === actor.user_id) return '自分';
  if (payload.assignee_user_id === actor.user_id) return '自分';
  return '自分';
}

function scheduleLabel(payload: Record<string, unknown>): string {
  const date = typeof payload.scheduled_date === 'string' ? payload.scheduled_date : '';
  const daypart = typeof payload.daypart === 'string' ? payload.daypart : null;
  const localTime = typeof payload.due_local_time === 'string' ? payload.due_local_time : null;
  const dateLabel = date ? `${Number(date.slice(5, 7))}/${Number(date.slice(8, 10))}` : '今日';
  // A concrete AI-extracted deadline (for example "10:00 出発") is more
  // useful than the broad daypart that was also present in the original text.
  const part =
    localTime ??
    (daypart ? daypartLabel(daypart as 'morning' | 'noon' | 'evening' | 'night') : '時刻なし');
  return `${dateLabel} ${part}`;
}

function previewDetailLines(payload: Record<string, unknown>): string[] {
  const lines: string[] = [];
  if (typeof payload.context === 'string' && payload.context.trim()) {
    lines.push(`予定: ${payload.context.trim()}`);
  }
  if (Array.isArray(payload.subtasks) && payload.subtasks.length > 0) {
    const subtasks = payload.subtasks
      .filter((item): item is string => typeof item === 'string' && item.trim().length > 0)
      .slice(0, 5)
      .map((item) => `・${item.trim()}`);
    if (subtasks.length > 0) lines.push('準備: ' + subtasks.join(' '));
  }
  return lines;
}

async function sendPendingActionPreview(
  client: SupabaseClient,
  item: WebhookInboxItem,
  actor: LineActor,
  pendingActionId: string,
  actionType: string,
  payload: Record<string, unknown>,
): Promise<void> {
  if (actionType === 'assignment_change_request') {
    const editUrl = `${Deno.env.get('APP_BASE_URL') ?? ''}/requests?pending=${pendingActionId}`;
    await replyOrEnqueuePush(client, {
      replyToken: item.payload.replyToken,
      lineUserId: item.source_external_user_id,
      householdId: actor.household_id,
      recipientUserId: actor.user_id,
      text: 'この内容で送りますか？',
      message: buildAssignmentSenderPreviewFlex({
        pendingActionId,
        title: String(payload.title ?? '担当変更'),
        message: String(payload.shared_message ?? '担当をお願いできますか？'),
        editUrl,
        scheduleLabel: payload.due_at
          ? new Intl.DateTimeFormat('ja-JP', {
              timeZone: 'Asia/Tokyo',
              month: 'numeric',
              day: 'numeric',
              hour: '2-digit',
              minute: '2-digit',
            }).format(new Date(String(payload.due_at)))
          : String(payload.scheduled_date ?? ''),
        scope: payload.scope === 'this_week' ? 'this_week' : 'once',
      }),
      dedupKey: `line-pending-preview:${item.provider_event_id}`,
    });
    return;
  }

  const kindLabel =
    actionType === 'request_create'
      ? 'お願い'
      : actionType === 'shopping_item_add'
        ? '買い物'
        : 'タスク';
  const confirmLabel = actionType === 'request_create' ? 'この内容で送る' : 'この内容で登録';
  await replyOrEnqueuePush(client, {
    replyToken: item.payload.replyToken,
    lineUserId: item.source_external_user_id,
    householdId: actor.household_id,
    recipientUserId: actor.user_id,
    text: `確認: ${String(payload.title ?? '')}`,
    message: buildPendingActionPreviewFlex({
      pendingActionId,
      kindLabel,
      title: String(payload.title ?? '予定'),
      scheduleLabel: scheduleLabel(payload),
      targetLabel:
        actionType === 'shopping_item_add' ? '買い物リスト' : targetLabel(payload, actor),
      detailLines: previewDetailLines(payload),
      confirmLabel,
    }),
    dedupKey: `line-pending-preview:${item.provider_event_id}`,
  });
}

function editQuickReplies(pendingActionId: string): LineQuickReplyAction[] {
  const pb = (label: string, field: string, value: string): LineQuickReplyAction => ({
    type: 'postback',
    label,
    data: `action=update_pending&pending_action_id=${pendingActionId}&field=${field}&value=${value}`,
    displayText: label,
  });
  return [
    pb('今日', 'date', 'today'),
    pb('明日', 'date', 'tomorrow'),
    pb('明後日', 'date', 'day_after'),
    pb('朝', 'time', 'morning'),
    pb('夕方', 'time', 'evening'),
    pb('夜', 'time', 'night'),
    pb('時刻なし', 'time', 'none'),
    pb('パパ', 'assignee', 'papa'),
    pb('ママ', 'assignee', 'mama'),
    pb('自分', 'assignee', 'self'),
    pb('タスク', 'kind', 'task'),
    pb('お願い', 'kind', 'request'),
    {
      type: 'postback',
      label: 'キャンセル',
      data: `action=cancel_pending&pending_action_id=${pendingActionId}`,
      displayText: 'キャンセル',
    },
  ];
}

async function handlePostback(
  client: SupabaseClient,
  item: WebhookInboxItem,
  actor: LineActor | null,
): Promise<void> {
  const data = item.payload.postback?.data;
  if (!data || !actor) return;
  const fields = parsePostbackData(data);

  if (fields.action === 'create_partner_invite' && fields.pending_action_id) {
    const pending = await getEditablePending(client, actor, fields.pending_action_id);
    if (!pending) {
      await sendConfirmation(client, item, actor, 'この下書きはすでに確定・期限切れです。');
      return;
    }
    await sendPartnerInviteLink(client, item, actor, pending.id);
    return;
  }

  if (fields.action === 'edit_pending' && fields.pending_action_id) {
    const pending = await getEditablePending(client, actor, fields.pending_action_id);
    if (!pending) {
      await sendConfirmation(client, item, actor, 'この入力はすでに確定・期限切れです。');
      return;
    }
    if (pending.action_type === 'assignment_change_request') {
      const quick: LineQuickReplyAction[] = [
        {
          type: 'postback',
          label: '今回だけ',
          data: `action=update_pending&pending_action_id=${fields.pending_action_id}&field=scope&value=once`,
          displayText: '今回だけ',
        },
        {
          type: 'postback',
          label: '今週だけ',
          data: `action=update_pending&pending_action_id=${fields.pending_action_id}&field=scope&value=this_week`,
          displayText: '今週だけ',
        },
        {
          type: 'postback',
          label: 'キャンセル',
          data: `action=cancel_pending&pending_action_id=${fields.pending_action_id}`,
          displayText: 'キャンセル',
        },
      ];
      await sendConfirmation(client, item, actor, '変更する範囲を選んでください。', quick);
      return;
    }
    const editPayload = { ...pending.normalized_payload, line_edit_mode: true };
    const marked = await updateEditablePending(
      client,
      actor,
      pending.id,
      pending.action_type,
      editPayload,
    );
    if (!marked) {
      await sendConfirmation(
        client,
        item,
        actor,
        '編集を開始できませんでした。元の確認カードからもう一度お試しください。',
      );
      return;
    }
    await sendConfirmation(
      client,
      item,
      actor,
      '修正したい内容をそのまま送れます。例:「ママじゃなくてパパ」「明日10時に変更」「タイトル: 皮膚科の準備」。下のボタンで選んでも大丈夫です。',
      editQuickReplies(fields.pending_action_id),
    );
    return;
  }

  if (
    fields.action === 'update_pending' &&
    fields.pending_action_id &&
    fields.field &&
    fields.value
  ) {
    const pending = await getEditablePending(client, actor, fields.pending_action_id);
    if (!pending) {
      await sendConfirmation(client, item, actor, 'この入力はすでに確定・期限切れです。');
      return;
    }
    let actionType = pending.action_type;
    const payload = { ...pending.normalized_payload };

    if (fields.field === 'scope' && actionType === 'assignment_change_request') {
      payload.scope = fields.value === 'this_week' ? 'this_week' : 'once';
    } else if (fields.field === 'date') {
      payload.scheduled_date =
        fields.value === 'tomorrow'
          ? jstIsoDateOffset(1)
          : fields.value === 'day_after'
            ? jstIsoDateOffset(2)
            : jstIsoDateOffset(0);
    } else if (fields.field === 'time') {
      const part =
        fields.value === 'morning' || fields.value === 'evening' || fields.value === 'night'
          ? fields.value
          : null;
      payload.daypart = part;
      payload.due_local_time = part ? daypartToLocalTime(part) : null;
    } else if (fields.field === 'assignee') {
      const selected =
        fields.value === 'self'
          ? actor.user_id
          : fields.value === 'papa' || fields.value === 'mama'
            ? await householdUserForRole(client, actor.household_id, fields.value)
            : null;
      if (!selected) {
        if (fields.value === 'papa' || fields.value === 'mama') {
          await sendMissingRoleRecovery(client, item, actor, pending.id, fields.value);
        } else {
          await sendConfirmation(
            client,
            item,
            actor,
            '担当者を変更できませんでした。下書きは変更していません。',
          );
        }
        return;
      }
      payload.target_label =
        fields.value === 'papa' ? 'パパ' : fields.value === 'mama' ? 'ママ' : '自分';
      if (actionType === 'shopping_item_add') {
        payload.assignee_user_id = selected;
      } else if (actionType === 'request_create') {
        actionType = 'request_create';
        payload.recipient_user_id = selected;
        delete payload.planned_assignee_user_id;
        if (!payload.shared_message)
          payload.shared_message = `${String(payload.title ?? 'この件')}をお願いできますか？`;
      } else {
        // A sender can create a task planned for either household member.
        // Only an explicit request is routed through recipient acceptance.
        actionType = 'task_create_once';
        payload.planned_assignee_user_id = selected;
        delete payload.recipient_user_id;
      }
    } else if (fields.field === 'kind') {
      if (fields.value === 'task') {
        actionType = 'task_create_once';
        payload.planned_assignee_user_id = actor.user_id;
        payload.target_label = '自分';
        delete payload.recipient_user_id;
      } else if (fields.value === 'request') {
        const partner = await partnerUserId(client, actor);
        if (!partner) {
          await sendConfirmation(client, item, actor, 'お願いを送る相手がまだ参加していません。');
          return;
        }
        actionType = 'request_create';
        payload.recipient_user_id = partner;
        payload.target_label = 'パートナー';
        delete payload.planned_assignee_user_id;
        if (!payload.shared_message)
          payload.shared_message = `${String(payload.title ?? 'この件')}をお願いできますか？`;
      }
    }

    delete payload.line_edit_mode;
    const result = await updateEditablePending(
      client,
      actor,
      fields.pending_action_id,
      actionType,
      payload,
    );
    if (!result) return;
    await sendPendingActionPreview(
      client,
      item,
      actor,
      result.id,
      result.action_type,
      result.normalized_payload,
    );
    return;
  }

  if (fields.action === 'confirm_pending' && fields.pending_action_id) {
    const { error } = await client.rpc('server_tx_confirm_pending_action', {
      p_actor_id: actor.user_id,
      p_pending_action_id: fields.pending_action_id,
    });
    if (error) {
      console.error('process-line-inbox: confirm_pending failed', error.message);
      return;
    }
    await sendConfirmation(
      client,
      item,
      actor,
      completionHint('✓ 確定しました。'),
      menuQuickReplies(),
    );
    return;
  }

  if (fields.action === 'cancel_pending' && fields.pending_action_id) {
    const { error } = await client.rpc('server_tx_cancel_pending_action', {
      p_actor_id: actor.user_id,
      p_pending_action_id: fields.pending_action_id,
    });
    if (error) {
      console.error('process-line-inbox: cancel_pending failed', error.message);
      return;
    }
    await sendConfirmation(client, item, actor, '✓ キャンセルしました');
    return;
  }

  if (fields.action === 'complete_task' && fields.task_id) {
    // #9's low-risk deterministic-completion exception: calls the normal
    // mutation contract directly rather than staging a pending_action.
    const operationId = await deterministicOperationId('line-postback', item.provider_event_id);
    const completionActor = fields.completion_actor === 'partner' ? 'partner' : 'self';
    const { error } = await client.rpc('server_tx_complete_task', {
      p_actor_id: actor.user_id,
      p_operation_id: operationId,
      p_task_id: fields.task_id,
      p_completion_actor: completionActor,
      p_complete_remaining_subtasks: fields.complete_remaining === 'true',
    });
    if (error) {
      console.error('process-line-inbox: complete_task postback failed', error.message);
      return;
    }
    await sendConfirmation(client, item, actor, '✓ 完了にしました');
    return;
  }

  if (fields.action === 'accept_assignment_change' && fields.request_id) {
    const operationId = await deterministicOperationId(
      'line-assignment-accept',
      item.provider_event_id,
    );
    const { error } = await client.rpc('server_tx_accept_assignment_change_request', {
      p_actor_id: actor.user_id,
      p_operation_id: operationId,
      p_request_id: fields.request_id,
    });
    if (error) {
      console.error('process-line-inbox: accept assignment change failed', error.message);
      return;
    }
    await sendConfirmation(client, item, actor, '✓ 担当を引き受けました');
    return;
  }

  if (fields.action === 'decline_assignment_change' && fields.request_id) {
    const operationId = await deterministicOperationId(
      'line-assignment-decline',
      item.provider_event_id,
    );
    const { error } = await client.rpc('server_tx_decline_request', {
      p_actor_id: actor.user_id,
      p_operation_id: operationId,
      p_request_id: fields.request_id,
    });
    if (error) {
      console.error('process-line-inbox: decline assignment change failed', error.message);
      return;
    }
    await sendConfirmation(client, item, actor, '変更はありません。');
    return;
  }

  if (fields.action === 'accept_request' && fields.request_id) {
    const operationId = await deterministicOperationId(
      'line-request-accept',
      item.provider_event_id,
    );
    const { error } = await client.rpc('server_tx_accept_request', {
      p_actor_id: actor.user_id,
      p_operation_id: operationId,
      p_request_id: fields.request_id,
    });
    if (error) {
      if (/REQUEST_NOT_PENDING|REQUEST_ACCEPT_NOT_ALLOWED/.test(error.message)) {
        await sendConfirmation(client, item, actor, 'このお願いはすでに処理済みです。');
      } else console.error('process-line-inbox: accept request failed', error.message);
      return;
    }
    await sendConfirmation(
      client,
      item,
      actor,
      completionHint('✓ 引き受けました。タスクに追加しました。'),
      menuQuickReplies(),
    );
    return;
  }

  if (fields.action === 'decline_request' && fields.request_id) {
    const operationId = await deterministicOperationId(
      'line-request-decline',
      item.provider_event_id,
    );
    const { error } = await client.rpc('server_tx_decline_request', {
      p_actor_id: actor.user_id,
      p_operation_id: operationId,
      p_request_id: fields.request_id,
    });
    if (error) {
      if (/REQUEST_NOT_PENDING|REQUEST_DECLINE_NOT_ALLOWED/.test(error.message)) {
        await sendConfirmation(client, item, actor, 'このお願いはすでに処理済みです。');
      } else console.error('process-line-inbox: decline request failed', error.message);
      return;
    }
    await sendConfirmation(client, item, actor, '今回は難しいとして返しました。');
    return;
  }

  if (
    fields.action === 'routine_item' &&
    fields.session_id &&
    fields.task_instance_id &&
    fields.value
  ) {
    if (!['complete', 'partner_handled', 'skip'].includes(fields.value)) {
      console.warn('process-line-inbox: invalid routine_item value', { value: fields.value });
      return;
    }
    const operationId = await deterministicOperationId('line-postback', item.provider_event_id);
    const { error } = await client.rpc('server_tx_routine_session_item_action', {
      p_actor_id: actor.user_id,
      p_operation_id: operationId,
      p_session_id: fields.session_id,
      p_task_instance_id: fields.task_instance_id,
      p_action: fields.value,
      p_source: 'line',
    });
    if (error) {
      console.error('process-line-inbox: routine_item postback failed', error.message);
      // #13 "old scheduled session superseded -> return SESSION_SUPERSEDED
      // and latest PWA link" -- the RPC layer raises TASK_TERMINAL for a
      // non-open session (docs/adr/0007 decision 2); reply with a safe
      // latest-state link rather than staying silent, since the tapped
      // button is now stale.
      if (error.message === 'TASK_TERMINAL') {
        await sendStaleSessionReply(client, item, actor, fields.session_id, null);
      }
      return;
    }
    const itemLabel =
      fields.value === 'complete'
        ? '✓ 完了にしました'
        : fields.value === 'partner_handled'
          ? '✓ 相手対応にしました'
          : '✓ 今回は不要にしました';
    // Re-review fix (P1-1) #8 "After an action, show the next unfinished
    // item until no items remain" -- re-reads the session's live state
    // (never trusts a locally-tracked cursor) and continues the
    // item-by-item flow, or announces completion once nothing is left.
    const session = await getRoutineSession(client, actor.user_id, fields.session_id);
    const next = session ? pickNextUnfinished(session.items) : null;
    if (next) {
      await sendItemPrompt(client, item, actor, fields.session_id, next, itemLabel);
    } else {
      await sendConfirmation(client, item, actor, `${itemLabel}\n\n✓ 全項目終わりました！`);
    }
    return;
  }

  // Re-review fix (P1-1): top-level "項目ごとに入力" -- loads the session
  // live and presents its first unfinished item with the four per-item
  // quick-reply actions. No mutation on this tap.
  if (fields.action === 'routine_item_mode' && fields.session_id) {
    const session = await getRoutineSession(client, actor.user_id, fields.session_id);
    if (!session || !session.can_act) {
      await sendStaleSessionReply(
        client,
        item,
        actor,
        fields.session_id,
        session?.current_session_id ?? null,
      );
      return;
    }
    const next = pickNextUnfinished(session.items);
    if (next) {
      await sendItemPrompt(client, item, actor, fields.session_id, next);
    } else {
      await sendConfirmation(client, item, actor, '✓ 未完了の項目はありません');
    }
    return;
  }

  // Re-review fix (P1-1): "次へ" -- advances past the given item WITHOUT
  // mutating it (docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md #8 "次へ advances
  // without mutating the current item").
  if (fields.action === 'routine_item_next' && fields.session_id) {
    const session = await getRoutineSession(client, actor.user_id, fields.session_id);
    if (!session || !session.can_act) {
      await sendStaleSessionReply(
        client,
        item,
        actor,
        fields.session_id,
        session?.current_session_id ?? null,
      );
      return;
    }
    const next = pickNextUnfinished(session.items, fields.task_instance_id ?? null);
    if (next) {
      await sendItemPrompt(client, item, actor, fields.session_id, next);
    } else {
      await sendConfirmation(client, item, actor, '✓ 未完了の項目はありません');
    }
    return;
  }

  if (fields.action === 'routine_complete' && fields.session_id && fields.value) {
    if (!['complete_all', 'skip_incomplete'].includes(fields.value)) {
      console.warn('process-line-inbox: invalid routine_complete value', { value: fields.value });
      return;
    }
    const operationId = await deterministicOperationId('line-postback', item.provider_event_id);
    const { error } = await client.rpc('server_tx_complete_routine_session', {
      p_actor_id: actor.user_id,
      p_operation_id: operationId,
      p_session_id: fields.session_id,
      p_disposition: fields.value,
      p_source: 'line',
    });
    if (error) {
      console.error('process-line-inbox: routine_complete postback failed', error.message);
      if (error.message === 'TASK_TERMINAL') {
        await sendStaleSessionReply(client, item, actor, fields.session_id, null);
      }
      return;
    }
    const sessionLabel =
      fields.value === 'complete_all' ? '✓ 全部完了にしました' : '✓ 今回は不要にしました';
    await sendConfirmation(client, item, actor, sessionLabel);
    return;
  }

  // Re-review fix (P1-2): the top-level "今回は不要" button no longer reaches
  // this far directly -- routineQuickReply.ts now points it at
  // routine_skip_prompt instead. This branch performs NO mutation; it only
  // reads the session (to gate on can_act / resolve a safe stale-session
  // link) and replies with a confirm/cancel prompt
  // (docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md #8 "確認を1段挟む"). Only the
  // "はい、今回は不要" branch below reaches the existing
  // routine_complete&value=skip_incomplete handler above, unchanged.
  if (fields.action === 'routine_skip_prompt' && fields.session_id) {
    const session = await getRoutineSession(client, actor.user_id, fields.session_id);
    if (!session || !session.can_act) {
      await sendStaleSessionReply(
        client,
        item,
        actor,
        fields.session_id,
        session?.current_session_id ?? null,
      );
      return;
    }
    const confirmQuickReply: LineQuickReplyAction[] = [
      {
        type: 'postback',
        label: 'はい、今回は不要',
        data: `action=routine_complete&session_id=${fields.session_id}&value=skip_incomplete`,
        displayText: 'はい、今回は不要',
      },
      {
        type: 'postback',
        label: '戻る',
        data: 'action=routine_cancel_prompt',
        displayText: '戻る',
      },
    ];
    await sendConfirmation(
      client,
      item,
      actor,
      '未完了の項目を「今回は不要」にしますか？',
      confirmQuickReply,
    );
    return;
  }

  // Re-review fix (P1-2): "戻る" -- explicitly no RPC call of any kind, so
  // there is nothing that could mutate a task even by accident.
  if (fields.action === 'routine_cancel_prompt') {
    await sendConfirmation(client, item, actor, 'キャンセルしました。変更はありません。');
    return;
  }

  console.warn('process-line-inbox: unrecognized postback action', {
    action: fields.action ?? null,
  });
}

async function handleText(
  client: SupabaseClient,
  item: WebhookInboxItem,
  actor: LineActor | null,
  text: string,
): Promise<void> {
  if (await tryClaimLinkToken(client, item.source_external_user_id, text)) return;
  if (!actor) return;
  if (await tryHandleReadOnlyText(client, item, actor, text)) return;
  if (await tryApplyLineTextEdit(client, item, actor, text)) return;

  const parsed = parseLineText(text);
  let assignmentPayload: Record<string, unknown> | null = null;

  // Existing pickup reassignment keeps its exact-task semantics; a generic
  // natural-language request must never create a second pickup task.
  if (!parsed && /(?:迎え.*お願い|お願い.*迎え)/.test(text)) {
    const scheduledDate = resolveJapanesePickupDate(text);
    const { data: definition } = await client
      .from('task_definitions')
      .select('id')
      .eq('household_id', actor.household_id)
      .eq('code', 'pickup')
      .maybeSingle();
    const { data: task } =
      definition && scheduledDate
        ? await client
            .from('task_instances')
            .select('id,title,due_at,scheduled_date')
            .eq('household_id', actor.household_id)
            .eq('task_definition_id', definition.id)
            .eq('scheduled_date', scheduledDate)
            .eq('planned_assignee_id', actor.user_id)
            .in('status', ['todo', 'in_progress'])
            .maybeSingle()
        : { data: null };
    const partner = await partnerUserId(client, actor);
    if (task && partner)
      assignmentPayload = {
        task_id: task.id,
        recipient_user_id: partner,
        raw_text: text,
        shared_message: rewritePickupRequest(text),
        scope: 'once',
        title: task.title,
        due_at: task.due_at,
        scheduled_date: task.scheduled_date,
      };
  }

  let actionType: string;
  let payload: Record<string, unknown>;
  if (assignmentPayload) {
    actionType = 'assignment_change_request';
    payload = assignmentPayload;
  } else if (parsed) {
    actionType = parsed.actionType;
    payload = { ...parsed.payload, raw_text: text };
    if (actionType === 'task_create_once' && !payload.planned_assignee_user_id) {
      payload.planned_assignee_user_id = actor.user_id;
      payload.target_label = '自分';
    }
  } else {
    const intent = await extractLineIntent(text);
    if (!intent) {
      actionType = 'needs_pwa_review';
      payload = { raw_text: text };
    } else {
      const targetUser = intent.targetRole
        ? await householdUserForRole(client, actor.household_id, intent.targetRole)
        : null;
      const dueLocalTime = intent.dueLocalTime ?? daypartToLocalTime(intent.daypart);
      const roleLabel =
        intent.targetRole === 'papa' ? 'パパ' : intent.targetRole === 'mama' ? 'ママ' : null;

      if (intent.kind === 'shopping') {
        actionType = 'shopping_item_add';
        payload = {
          raw_text: text,
          title: intent.title,
          purchase_method: /amazon|アマゾン/i.test(text) ? 'amazon' : 'store',
          assignee_user_id: targetUser,
          scheduled_date: intent.scheduledDate,
          due_local_time: dueLocalTime,
          daypart: intent.daypart,
          context: intent.context,
          calendar_visibility: intent.calendarVisibility,
          target_label: roleLabel ?? '買い物リスト',
          parse_source: intent.source,
        };
      } else {
        const recipient =
          intent.kind === 'request' ? (targetUser ?? (await partnerUserId(client, actor))) : null;
        if (recipient && recipient !== actor.user_id) {
          actionType = 'request_create';
          payload = {
            raw_text: text,
            title: intent.title,
            shared_message: intent.sharedMessage ?? `${intent.title}をお願いできますか？`,
            recipient_user_id: recipient,
            scheduled_date: intent.scheduledDate,
            due_local_time: dueLocalTime,
            daypart: intent.daypart,
            context: intent.context,
            calendar_visibility: intent.calendarVisibility,
            target_label: roleLabel ?? 'パートナー',
            parse_source: intent.source,
          };
        } else {
          actionType = 'task_create_once';
          payload = {
            raw_text: text,
            title: intent.title,
            category: 'todo',
            scheduled_date: intent.scheduledDate,
            due_local_time: dueLocalTime,
            planned_assignee_user_id: targetUser ?? actor.user_id,
            routine_phase: 'anytime',
            daypart: intent.daypart,
            subtasks: intent.subtasks,
            context: intent.context,
            calendar_visibility: intent.calendarVisibility,
            target_label: roleLabel ?? '自分',
            parse_source: intent.source,
          };
        }
      }
    }
  }

  const operationId = await deterministicOperationId('line-text', item.provider_event_id);
  const { data: pendingData, error } = await client.rpc('server_tx_create_pending_action', {
    p_actor_id: actor.user_id,
    p_household_id: actor.household_id,
    p_operation_id: operationId,
    p_source: 'line',
    p_action_type: actionType,
    p_normalized_payload: payload,
    p_ttl_minutes: PENDING_ACTION_TTL_MINUTES,
  });
  if (error) {
    console.error('process-line-inbox: create_pending_action failed', error.message);
    return;
  }

  const pendingActionId = pendingData?.pending_action_id as string | undefined;
  if (pendingActionId && actionType !== 'needs_pwa_review') {
    await sendPendingActionPreview(client, item, actor, pendingActionId, actionType, payload);
    return;
  }

  await sendConfirmation(
    client,
    item,
    actor,
    'うまく予定に変換できませんでした。「明日の朝、歯医者の予約をママにお願い」のように、いつ・何を・誰がを入れてもう一度送ってください。入力はアプリの判断待ちにも残しています。',
  );
}

async function processItem(client: SupabaseClient, item: WebhookInboxItem): Promise<void> {
  const actor = await resolveActor(client, item.source_external_user_id);

  if (item.payload.type === 'postback') {
    await handlePostback(client, item, actor);
  } else if (item.payload.type === 'message' && item.payload.message?.type === 'text') {
    await handleText(client, item, actor, item.payload.message.text ?? '');
  }
  // Other event types (follow/unfollow/join/beacon/etc.) are durably stored
  // but have no v6-documented action — acknowledged as done, no side effect.
}

Deno.serve(
  withServiceHandler(async (req: Request) => {
    requireWorkerToken(req); // throws EDGE_WORKER_UNAUTHORIZED before any DB access

    const client = createServiceRoleClient();

    const { data: batchData, error: claimError } = await client.rpc(
      'server_tx_claim_webhook_inbox_batch',
      {
        p_worker_id: WORKER_ID,
        p_limit: BATCH_LIMIT,
        p_lease_seconds: LEASE_SECONDS,
      },
    );
    if (claimError) {
      console.error('process-line-inbox: claim batch failed', claimError.message);
      return new Response(
        JSON.stringify({ error: { code: 'INTERNAL_ERROR', message: 'internal error' } }),
        {
          status: 500,
          headers: { 'Content-Type': 'application/json' },
        },
      );
    }

    const items = (batchData ?? []) as WebhookInboxItem[];
    let succeeded = 0;
    let failed = 0;

    for (const item of items) {
      try {
        await processItem(client, item);
        const { data: completeData } = await client.rpc('server_tx_complete_webhook_inbox_item', {
          p_id: item.id,
          p_lease_token: item.lease_token,
        });
        if ((completeData as { ok?: boolean } | null)?.ok) succeeded++;
      } catch (err) {
        failed++;
        const message = err instanceof Error ? err.message : String(err);
        console.error('process-line-inbox: item processing failed', { id: item.id, message });
        await client.rpc('server_tx_fail_webhook_inbox_item', {
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

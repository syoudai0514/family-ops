// P1-4 fix (independent design review by "Sol"): shared reply-first LINE
// delivery helper. docs/design/v6/06_LINE_INTEGRATION.md #10A "Reply":
// "When a current webhook reply token can satisfy the interaction, use
// Reply API first. Reply messages do not consume counted monthly push
// allowance." / #12 "Immediate user interaction may use reply token if
// valid, but required durable state/notification cannot rely solely on
// reply token."
//
// New file per the fix's own file-boundary note -- existing _shared/*.ts
// files (auth.ts, errors.ts, handler.ts) are owned by other in-flight work
// and are intentionally left untouched. Both process-line-inbox and
// send-notifications import from here so the LINE Reply API call style,
// the PWA deep-link builder, and the quick-reply item shape all have one
// definition.
//
// Reply tokens are LINE-webhook-scoped, one-time-use, and expire quickly
// (LINE does not document an exact TTL). Per the design doc's own guidance,
// this helper does not try to predict expiry from timestamps -- it always
// ATTEMPTS the reply when a token is present and treats any non-2xx
// response (LINE returns 400 for expired/already-used/invalid tokens) or
// network failure as "unavailable", falling back immediately to a durable
// push-outbox row. The reply path never calls server_tx_reserve_line_quota
// or any other quota RPC -- only the push-fallback path (via
// server_tx_enqueue_immediate_line_push, 20260819000100) creates a
// notification_outbox row, which is later drained by send-notifications
// through its own existing quota-reserve/push logic exactly like any other
// queued LINE message.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

const LINE_REPLY_URL = 'https://api.line.me/v2/bot/message/reply';
// Matches the FETCH_TIMEOUT_MS constant/style already used for provider
// calls in send-notifications/index.ts.
const REPLY_FETCH_TIMEOUT_MS = 10_000;

export interface LinePostbackQuickReplyAction {
  type: 'postback';
  label: string;
  data: string;
  displayText?: string;
}

// Re-review fix (P1-1, docs/adr/0010): the top-level "PWAで開く" quick-reply
// button (17_ROUTINE_LINE_AUTOMATION.md #8 top-level action 4) opens the
// checkin link directly rather than round-tripping through a postback.
export interface LineUriQuickReplyAction {
  type: 'uri';
  label: string;
  uri: string;
}

export interface LineMessageQuickReplyAction {
  type: 'message';
  label: string;
  text: string;
}

export type LineQuickReplyAction =
  LinePostbackQuickReplyAction | LineUriQuickReplyAction | LineMessageQuickReplyAction;

export interface ReplyOrEnqueuePushArgs {
  /** private.webhook_inbox item's payload.replyToken for THIS event, or null/undefined if none/already-used. Never logged in full. */
  replyToken: string | null | undefined;
  /** The recipient's active LINE user id (only used for a no-channel short-circuit; the push-fallback RPC re-resolves this itself). */
  lineUserId: string | null | undefined;
  householdId: string;
  recipientUserId: string;
  text: string;
  message?: Record<string, unknown>;
  quickReplyItems?: LineQuickReplyAction[];
  /** Stable key (e.g. derived from the webhook's provider_event_id) so a redelivered event's fallback push does not double-enqueue. */
  dedupKey?: string;
}

export type ReplyOrEnqueueResult = 'replied' | 'push_fallback' | 'no_channel';

async function fetchWithTimeout(url: string, init: RequestInit): Promise<Response> {
  return await fetch(url, { ...init, signal: AbortSignal.timeout(REPLY_FETCH_TIMEOUT_MS) });
}

function buildLineMessages(
  text: string,
  quickReplyItems?: LineQuickReplyAction[],
  richMessage?: Record<string, unknown>,
) {
  if (richMessage) return [richMessage];
  const message: Record<string, unknown> = { type: 'text', text };
  if (quickReplyItems && quickReplyItems.length > 0) {
    message.quickReply = { items: quickReplyItems.map((action) => ({ type: 'action', action })) };
  }
  return [message];
}

/** {APP_BASE_URL}/checkin/{session_id} -- 06_LINE_INTEGRATION.md #8 "No bearer credential in URL". */
export function buildCheckinLink(sessionId: string): string {
  const base = Deno.env.get('APP_BASE_URL') ?? '';
  return `${base}/checkin/${sessionId}`;
}

// Attempts LINE's Reply API first (no quota RPC involved at all -- reply
// sends never count toward APP_LINE_MONTHLY_HARD_CAP per #10A). Any
// non-2xx/network/missing-input condition is treated as "reply unavailable"
// and falls back to a durable, immediate-priority push outbox row via
// server_tx_enqueue_immediate_line_push rather than ever calling the LINE
// push endpoint directly from here -- push delivery, quota accounting, and
// retry-key handling all stay owned by send-notifications.
export async function replyOrEnqueuePush(
  serviceClient: SupabaseClient,
  args: ReplyOrEnqueuePushArgs,
): Promise<ReplyOrEnqueueResult> {
  const channelAccessToken = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN');

  if (args.replyToken && channelAccessToken) {
    try {
      const response = await fetchWithTimeout(LINE_REPLY_URL, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${channelAccessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          replyToken: args.replyToken,
          messages: buildLineMessages(args.text, args.quickReplyItems, args.message),
        }),
      });
      if (response.ok) {
        return 'replied';
      }
      // Never log the token itself -- only the outcome.
      console.warn('lineMessaging: reply API non-2xx, falling back to push outbox', {
        status: response.status,
      });
    } catch (err) {
      console.warn('lineMessaging: reply API request failed, falling back to push outbox', {
        message: err instanceof Error ? err.message : String(err),
      });
    }
  }

  if (!args.lineUserId) {
    return 'no_channel'; // no reply token attempted/available AND no linked LINE user to push to
  }

  const { error } = await serviceClient.rpc('server_tx_enqueue_immediate_line_push', {
    p_household_id: args.householdId,
    p_recipient_user_id: args.recipientUserId,
    p_text: args.text,
    p_dedup_key: args.dedupKey ?? null,
    p_rich_message: args.message ?? null,
  });
  if (error) {
    console.error('lineMessaging: push-fallback enqueue failed', error.message);
    return 'no_channel';
  }
  return 'push_fallback';
}

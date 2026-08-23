// Re-review fix (P1-1, docs/adr/0010): pure, dependency-free helpers for the
// LINE-native "項目ごとに入力" (item-by-item) flow
// (docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md #8). Split out from
// index.ts specifically so the deterministic-selection and message-shape
// logic is unit-testable without a live LINE provider or database — see
// routineItemFlow.test.ts.
//
// The item list handed in here always comes from a live
// server_tx_get_routine_session call (already ordered by display_order),
// so "deterministic" means: given the same DB state, the same item is
// always picked next — no reliance on any separately-tracked cursor state
// beyond the task_instance_id LINE echoes back in each button's postback
// data.
import type { LinePostbackQuickReplyAction } from "../_shared/lineMessaging.ts";
import { buildCheckinLink } from "../_shared/lineMessaging.ts";

export interface RoutineSessionItem {
  task_instance_id: string;
  title: string;
  status: string;
  display_order?: number;
}

const UNFINISHED_STATUSES = new Set(["todo", "in_progress"]);

export function unfinishedItems(
  items: RoutineSessionItem[],
): RoutineSessionItem[] {
  return items.filter((i) => UNFINISHED_STATUSES.has(i.status));
}

// "Starting item-by-item mode selects the first unfinished item
// deterministically" -- items are already ordered by display_order by the
// RPC that produced them; this never re-sorts, only filters.
//
// For "次へ" (afterTaskInstanceId set, no mutation): advances to the
// unfinished item immediately after the given cursor, wrapping back to the
// first unfinished item once the end of the list is reached (so items a
// user pages past with 次へ come back around rather than being permanently
// skipped without ever being acted on). If the cursor item is no longer in
// the unfinished set (e.g. completed concurrently via PWA -- SL-17), there
// is no well-defined "after" position, so this restarts from the first
// unfinished item rather than guessing.
export function pickNextUnfinished(
  items: RoutineSessionItem[],
  afterTaskInstanceId?: string | null,
): RoutineSessionItem | null {
  const pending = unfinishedItems(items);
  if (pending.length === 0) return null;
  if (!afterTaskInstanceId) return pending[0];
  const idx = pending.findIndex((i) =>
    i.task_instance_id === afterTaskInstanceId
  );
  if (idx === -1) return pending[0];
  return pending[(idx + 1) % pending.length];
}

// Each item's four required quick-reply actions
// (17_ROUTINE_LINE_AUTOMATION.md #8 "項目ごとに入力": 完了/相手が対応/今回は不要/次へ).
// data carries only opaque resource ids (session_id, task_instance_id) --
// no bearer secret, matching the existing routine_item/routine_complete
// postback contract this reuses unchanged for 完了/相手が対応/今回は不要.
export function buildItemQuickReply(
  sessionId: string,
  taskInstanceId: string,
): LinePostbackQuickReplyAction[] {
  return [
    {
      type: "postback",
      label: "完了",
      data:
        `action=routine_item&session_id=${sessionId}&task_instance_id=${taskInstanceId}&value=complete`,
      displayText: "完了",
    },
    {
      type: "postback",
      label: "相手が対応",
      data:
        `action=routine_item&session_id=${sessionId}&task_instance_id=${taskInstanceId}&value=partner_handled`,
      displayText: "相手が対応",
    },
    {
      type: "postback",
      label: "今回は不要",
      data:
        `action=routine_item&session_id=${sessionId}&task_instance_id=${taskInstanceId}&value=skip`,
      displayText: "今回は不要",
    },
    {
      type: "postback",
      label: "次へ",
      data:
        `action=routine_item_next&session_id=${sessionId}&task_instance_id=${taskInstanceId}`,
      displayText: "次へ",
    },
  ];
}

// The PWA link is always folded into the item prompt text itself (not only
// attached as a quick-reply button) so requirement #7 ("PWA remains
// available as fallback") holds even when a reply attempt fails and the
// confirmation degrades to a plain-text push-outbox fallback that cannot
// carry the postback buttons (see lineMessaging.ts's push-fallback path).
export function buildItemPromptText(
  sessionId: string,
  item: RoutineSessionItem,
): string {
  return `📝 次の項目\n・${item.title}\n\n${buildCheckinLink(sessionId)}`;
}

// docs/adr/0007 decision 2's existing pattern, reused here: a
// superseded/submitted/auto_closed session, or one this actor no longer
// owns, must never mutate -- only ever resolve to the latest safe link.
export function buildStaleSessionText(
  currentSessionId: string | null,
  fallbackSessionId: string,
): string {
  const link = buildCheckinLink(currentSessionId ?? fallbackSessionId);
  return `⚠ このチェックは最新ではありません。最新の状態はこちら:\n${link}`;
}

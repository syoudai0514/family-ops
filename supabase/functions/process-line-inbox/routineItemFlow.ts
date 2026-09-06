// LINE-native per-item reconciliation helpers. Q64 uses the same seven
// canonical outcomes as PWA; "次へ" is the only non-mutating action.
import type { LinePostbackQuickReplyAction } from "../_shared/lineMessaging.ts";
import { buildCheckinLink } from "../_shared/lineMessaging.ts";

export interface RoutineSessionItem {
  task_instance_id: string;
  title: string;
  status: string;
  display_order?: number;
}

const UNFINISHED_STATUSES = new Set(["todo", "in_progress"]);

export function unfinishedItems(items: RoutineSessionItem[]): RoutineSessionItem[] {
  return items.filter((i) => UNFINISHED_STATUSES.has(i.status));
}

export function pickNextUnfinished(items: RoutineSessionItem[], afterTaskInstanceId?: string | null): RoutineSessionItem | null {
  const pending = unfinishedItems(items);
  if (pending.length === 0) return null;
  if (!afterTaskInstanceId) return pending[0];
  const idx = pending.findIndex((i) => i.task_instance_id === afterTaskInstanceId);
  if (idx === -1) return pending[0];
  return pending[(idx + 1) % pending.length];
}

function mutation(sessionId: string, taskInstanceId: string, value: string, label: string): LinePostbackQuickReplyAction {
  return { type: "postback", label, data: `action=routine_item&session_id=${sessionId}&task_instance_id=${taskInstanceId}&value=${value}`, displayText: label };
}

export function buildItemQuickReply(sessionId: string, taskInstanceId: string): LinePostbackQuickReplyAction[] {
  return [
    mutation(sessionId, taskInstanceId, "complete", "完了"),
    mutation(sessionId, taskInstanceId, "partner_handled", "相手が対応"),
    mutation(sessionId, taskInstanceId, "failed", "できなかった"),
    mutation(sessionId, taskInstanceId, "skip", "今回は不要"),
    mutation(sessionId, taskInstanceId, "cancelled", "中止"),
    mutation(sessionId, taskInstanceId, "rescheduled", "明日に再予定"),
    mutation(sessionId, taskInstanceId, "unknown", "不明"),
    { type: "postback", label: "次へ", data: `action=routine_item_next&session_id=${sessionId}&task_instance_id=${taskInstanceId}`, displayText: "次へ" },
  ];
}

export function buildItemPromptText(sessionId: string, item: RoutineSessionItem): string {
  return `📝 次の項目\n・${item.title}\n\n${buildCheckinLink(sessionId)}`;
}

export function buildStaleSessionText(currentSessionId: string | null, fallbackSessionId: string): string {
  const link = buildCheckinLink(currentSessionId ?? fallbackSessionId);
  return `⚠ このチェックは最新ではありません。最新の状態はこちら:\n${link}`;
}

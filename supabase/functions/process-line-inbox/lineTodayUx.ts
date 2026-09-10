import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";

type JsonObject = Record<string, unknown>;

function record(value: unknown): JsonObject | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as JsonObject
    : null;
}

function records(value: unknown): JsonObject[] {
  return Array.isArray(value) ? value.map(record).filter((v): v is JsonObject => Boolean(v)) : [];
}

function message(label: string, text = label): LineQuickReplyAction {
  return { type: "message", label, text };
}

export function appendTodayDetailLinks(text: string, briefValue: unknown, appBaseUrl: string): string {
  const base = appBaseUrl.replace(/\/$/, "");
  if (!base) return text;
  const brief = record(briefValue) ?? {};
  const activeInfos = records(brief.active_infos);
  const tomorrow = record(brief.tomorrow_impact) ?? {};
  const impactCount = typeof tomorrow.impact_count === "number" ? tomorrow.impact_count : 0;

  const lines = ["詳しく見る", `・今日の一覧 ${base}/today`];
  if (activeInfos.length > 0) lines.push(`・引き継ぎ・共有 ${base}/handovers`);
  if (impactCount > 0) lines.push(`・明日の予定・準備 ${base}/week`);
  return `${text}\n\n${lines.join("\n")}`;
}

export function todayContextQuickReplies(
  briefValue: unknown,
  baseActions: LineQuickReplyAction[],
): LineQuickReplyAction[] {
  const brief = record(briefValue) ?? {};
  const urgent = records(brief.urgent_actions);
  const activeInfos = records(brief.active_infos);
  const contextual: LineQuickReplyAction[] = [];

  if (urgent.some((item) => typeof item.request_id === "string")) {
    contextual.push(message("お願いを確認", "お願いの返事"));
  }
  if (activeInfos.some((item) => item.ack_policy === "required")) {
    contextual.push(message("共有を確認", "共有確認"));
  }

  return [...contextual, ...baseActions].slice(0, 13);
}

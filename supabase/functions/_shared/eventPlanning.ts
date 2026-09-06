import { callGemini } from "./gemini.ts";

export type EventTemplateKey = "birthday" | "school" | "medical" | "ceremony" | "trip" | "custom";

export interface EventTodoCandidate {
  candidate_id: string;
  source: "template" | "ai";
  title: string;
  scheduled_date: string;
  reason?: string;
}

const TEMPLATES: Record<EventTemplateKey, Array<{ title: string; offset: number }>> = {
  birthday: [
    { title: "プレゼントを準備する", offset: -7 },
    { title: "ケーキ・食事を確認する", offset: -3 },
  ],
  school: [
    { title: "持ち物を確認する", offset: -2 },
    { title: "当日の時間・場所を確認する", offset: -1 },
  ],
  medical: [
    { title: "診察券・保険証などを準備する", offset: -1 },
    { title: "受診時に伝えることを確認する", offset: -1 },
  ],
  ceremony: [
    { title: "服装・持ち物を確認する", offset: -7 },
    { title: "当日の移動・集合を確認する", offset: -2 },
  ],
  trip: [
    { title: "必要な予約を確認する", offset: -14 },
    { title: "荷物を準備する", offset: -2 },
  ],
  custom: [],
};

export const EVENT_TEMPLATE_LABELS: Record<EventTemplateKey, string> = {
  birthday: "誕生日",
  school: "園・学校行事",
  medical: "通院・予防接種",
  ceremony: "式典・家族行事",
  trip: "旅行・外出",
  custom: "その他",
};

export function isEventTemplateKey(value: unknown): value is EventTemplateKey {
  return typeof value === "string" && value in TEMPLATES;
}

function addDaysIso(isoDate: string, offset: number): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(isoDate);
  if (!match) throw new Error("EVENT_DATE_INVALID");
  const date = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])));
  if (Number.isNaN(date.getTime())) throw new Error("EVENT_DATE_INVALID");
  date.setUTCDate(date.getUTCDate() + offset);
  return date.toISOString().slice(0, 10);
}

export function buildTemplateCandidates(
  templateKey: EventTemplateKey,
  eventDate: string,
): EventTodoCandidate[] {
  return TEMPLATES[templateKey].map((item, index) => ({
    candidate_id: `template-${templateKey}-${index + 1}`,
    source: "template" as const,
    title: item.title,
    scheduled_date: addDaysIso(eventDate, item.offset),
  }));
}

function extractJson(text: string): string {
  const match = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  return (match ? match[1] : text).trim();
}

export function parseAiEventCandidates(raw: string, eventDate: string): EventTodoCandidate[] {
  let value: unknown;
  try {
    value = JSON.parse(extractJson(raw));
  } catch {
    throw new Error("EVENT_AI_INVALID_JSON");
  }
  if (typeof value !== "object" || value === null) throw new Error("EVENT_AI_INVALID_SHAPE");
  const rows = (value as Record<string, unknown>).todo_candidates;
  if (!Array.isArray(rows) || rows.length > 8) throw new Error("EVENT_AI_INVALID_SHAPE");

  return rows.map((row, index) => {
    if (typeof row !== "object" || row === null) throw new Error("EVENT_AI_INVALID_SHAPE");
    const item = row as Record<string, unknown>;
    const title = typeof item.title === "string" ? item.title.trim() : "";
    const offset = item.offset_days;
    const reason = typeof item.reason === "string" ? item.reason.trim() : "";
    if (title.length < 1 || title.length > 240 || !Number.isInteger(offset) || (offset as number) < -90 || (offset as number) > 0) {
      throw new Error("EVENT_AI_INVALID_SHAPE");
    }
    if (reason.length > 500) throw new Error("EVENT_AI_INVALID_SHAPE");
    return {
      candidate_id: `ai-${index + 1}`,
      source: "ai" as const,
      title,
      scheduled_date: addDaysIso(eventDate, offset as number),
      ...(reason ? { reason } : {}),
    };
  });
}

export async function proposeEventTodoCandidates(input: {
  templateKey: EventTemplateKey;
  eventDate: string;
  title: string;
  details?: string;
  location?: string;
}): Promise<EventTodoCandidate[]> {
  const model = Deno.env.get("GEMINI_MODEL_REWRITE") ?? "";
  const prompt = [
    "家庭イベントの準備ToDo候補を作ってください。候補は人が確認してから登録します。",
    "入力に書かれていない担当者・予約済み事実・日時を捏造しないでください。",
    "イベント後の日付になる候補は禁止です。候補は最大8件、必要なものだけに絞ってください。",
    'JSONのみ: {"todo_candidates":[{"title":string,"offset_days":integer(-90..0),"reason":string}]}',
    `テンプレート種別: ${EVENT_TEMPLATE_LABELS[input.templateKey]}`,
    `イベント日: ${input.eventDate}`,
    `タイトル: ${input.title}`,
    `場所: ${input.location ?? ""}`,
    `入力内容: ${input.details ?? ""}`,
  ].join("\n");
  return parseAiEventCandidates(await callGemini(prompt, model), input.eventDate);
}

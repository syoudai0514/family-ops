import { callGemini } from "../_shared/gemini.ts";

export type LineIntentKind = "task" | "request" | "shopping";
export type LineDaypart = "morning" | "noon" | "evening" | "night" | null;
export type LineTargetRole = "papa" | "mama" | null;

export type LineIntent = {
  kind: LineIntentKind;
  title: string;
  scheduledDate: string;
  dueLocalTime: string | null;
  daypart: LineDaypart;
  targetRole: LineTargetRole;
  sharedMessage: string | null;
  /** Small, actionable checklist items. They become canonical task subtasks. */
  subtasks: string[];
  /** Context shown in the sender preview; it is never used to infer a task. */
  context: string | null;
  /** Explicit visibility decision, independent from category/title. */
  calendarVisibility: "special" | "hidden";
  source: "deterministic" | "gemini";
};

/**
 * Menu/guidance phrases express an intention to start adding something, not
 * the task itself. Never let Gemini turn these into placeholder titles such
 * as "タスクの追加". Returning null makes the existing safe clarification path
 * ask for the actual content instead of creating a bogus pending action.
 */
export function isLineCreateStarter(text: string): boolean {
  const value = text
    .normalize("NFKC")
    .replace(/\s+/g, "")
    .replace(/[。.!！?？]+$/g, "");
  return /^(?:(?:パパ|ママ|父|母|お父さん|お母さん|嫁さん|奥さん|妻)に)?(?:(?:今日|明日|明後日)(?:の)?(?:朝|昼|夕方|夜)?(?:の|に)?)?(?:(?:予定|単発予定)(?:を)?追加したい|タスク(?:を)?追加したい|お願い(?:を)?送りたい|買い物(?:を)?追加したい)$/
    .test(
      value,
    );
}

const JST_OFFSET_MS = 9 * 60 * 60 * 1000;

function jstDateParts(now: Date): { year: number; month: number; day: number } {
  const shifted = new Date(now.getTime() + JST_OFFSET_MS);
  return {
    year: shifted.getUTCFullYear(),
    month: shifted.getUTCMonth() + 1,
    day: shifted.getUTCDate(),
  };
}

function dateToIso(year: number, month: number, day: number): string {
  return `${year.toString().padStart(4, "0")}-${
    month.toString().padStart(2, "0")
  }-${
    day
      .toString()
      .padStart(2, "0")
  }`;
}

function addJstDays(now: Date, days: number): string {
  const parts = jstDateParts(now);
  const utc = new Date(Date.UTC(parts.year, parts.month - 1, parts.day + days));
  return dateToIso(
    utc.getUTCFullYear(),
    utc.getUTCMonth() + 1,
    utc.getUTCDate(),
  );
}

function resolveFirstRelativeDate(text: string, now: Date): string {
  const match = text.match(/今夜|今朝|今日|明後日|明日/);
  if (!match) return addJstDays(now, 0);
  if (match[0] === "明後日") return addJstDays(now, 2);
  if (match[0] === "明日") return addJstDays(now, 1);
  return addJstDays(now, 0);
}

function resolveDaypart(text: string): LineDaypart {
  const first = text.match(/今朝|朝|昼|夕方|夜|今夜/);
  if (!first) return null;
  if (first[0] === "今朝" || first[0] === "朝") return "morning";
  if (first[0] === "昼") return "noon";
  if (first[0] === "夕方") return "evening";
  return "night";
}

export function daypartToLocalTime(daypart: LineDaypart): string | null {
  switch (daypart) {
    case "morning":
      return "08:00";
    case "noon":
      return "12:00";
    case "evening":
      return "18:00";
    case "night":
      return "20:00";
    default:
      return null;
  }
}

export function daypartLabel(daypart: LineDaypart): string {
  switch (daypart) {
    case "morning":
      return "朝";
    case "noon":
      return "昼";
    case "evening":
      return "夕方";
    case "night":
      return "夜";
    default:
      return "時刻なし";
  }
}

function targetRole(text: string): LineTargetRole {
  // A correction such as "ママじゃなくてパパ" must select the replacement,
  // not the first name mentioned.  This is used both for a fresh LINE input
  // and for a draft correction, so keep it deterministic instead of relying
  // on the model to infer Japanese contrast grammar every time.
  const correction = text.match(
    /(?:パパ|父|お父さん|ママ|母|お母さん|嫁さん|奥さん|妻)\s*(?:じゃなくて|ではなくて|ではなく|じゃなく|の代わりに)\s*(パパ|父|お父さん|ママ|母|お母さん|嫁さん|奥さん|妻)/,
  );
  if (correction) {
    return /^(?:パパ|父|お父さん)$/.test(correction[1]) ? "papa" : "mama";
  }
  if (/(?:パパ|父|お父さん)/.test(text)) return "papa";
  if (/(?:ママ|母|お母さん|嫁さん|奥さん|妻)/.test(text)) return "mama";
  return null;
}

function cleanNoun(value: string): string {
  return value
    .replace(/^(?:嫁さん|奥さん|妻|ママ|パパ)[、,\s]*/u, "")
    .replace(/(?:今日|明日|明後日)(?:の)?(?:朝|昼|夕方|夜)?[に、,\s]*/gu, "")
    .replace(/今夜[に、,\s]*/gu, "")
    .replace(/^(?:朝|昼|夕方|夜)[に、,\s]*/u, "")
    .replace(/明日の(?=(?:病院|歯医者|保育園|幼稚園|学校))/gu, "")
    .trim();
}

function isTokyoIsoDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const [year, month, day] = value.split("-").map(Number);
  const parsed = new Date(Date.UTC(year, month - 1, day));
  return (
    parsed.getUTCFullYear() === year &&
    parsed.getUTCMonth() + 1 === month &&
    parsed.getUTCDate() === day
  );
}

function cleanShortText(value: unknown, maxLength: number): string | null {
  if (typeof value !== "string") return null;
  const text = value.replace(/\s+/g, " ").trim();
  return text && text.length <= maxLength ? text : null;
}

function cleanSubtasks(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const seen = new Set<string>();
  const subtasks: string[] = [];
  for (const item of value) {
    const title = cleanShortText(item, 60);
    if (!title || seen.has(title)) continue;
    seen.add(title);
    subtasks.push(title);
    if (subtasks.length === 5) break;
  }
  return subtasks;
}

/**
 * Convert the untrusted/preview checklist into the exact RPC payload used for
 * canonical task subtasks.  Keeping this next to the model-response boundary
 * means a confirm can never turn a long raw sentence into a subtask.
 */
export function toTaskSubtasks(
  value: unknown,
): Array<{ title: string; required: boolean; sort_order: number }> | null {
  const titles = cleanSubtasks(value);
  return titles.length > 0
    ? titles.map((title, index) => ({
      title,
      required: true,
      sort_order: index + 1,
    }))
    : null;
}

export function deterministicLineIntent(
  text: string,
  now = new Date(),
): LineIntent | null {
  const normalized = text
    .normalize("NFKC")
    .replace(/よやく/g, "予約")
    .replace(/\s+/g, " ")
    .trim();
  if (!normalized) return null;

  const scheduledDate = resolveFirstRelativeDate(normalized, now);
  const daypart = resolveDaypart(normalized);
  const role = targetRole(normalized);
  const requestSignal =
    /(?:してほしい|して欲しい|お願い|頼め|頼み|やってほしい|やって欲しい|してくれる|してもら|お願いでき)/
      .test(
        normalized,
      );
  const shoppingSignal = /(?:買って|買う|購入|注文して|注文する)/.test(
    normalized,
  );

  if (shoppingSignal) {
    const item = cleanNoun(
      normalized
        .replace(/(?:Amazon|アマゾン)で?/gi, "")
        .replace(/(?:買って|買う|購入して|購入する|注文して|注文する).*/u, ""),
    );
    if (item.length >= 1 && item.length <= 80) {
      return {
        kind: "shopping",
        title: item,
        scheduledDate,
        dueLocalTime: null,
        daypart,
        targetRole: role,
        sharedMessage: null,
        subtasks: [],
        context: null,
        calendarVisibility: "hidden",
        source: "deterministic",
      };
    }
  }

  const reservation = normalized.match(
    /(.{1,50}?)の予約(?:を)?(?:して|し|お願い)/u,
  );
  if (reservation) {
    const noun = cleanNoun(reservation[1]);
    if (noun) {
      const title = `${noun}の予約`;
      return {
        kind: requestSignal ? "request" : "task",
        title,
        scheduledDate,
        dueLocalTime: null,
        daypart,
        targetRole: role,
        sharedMessage: `${title}をお願いできますか？`,
        subtasks: [],
        context: null,
        calendarVisibility: "hidden",
        source: "deterministic",
      };
    }
  }

  const insurance = normalized.match(/(.{0,40}?)(?:の)?保険証(?:の)?準備/u);
  if (insurance) {
    let prefix = cleanNoun(insurance[1] ?? "")
      .replace(/(?:しなくちゃ.*|しないと.*)$/u, "")
      .trim();
    prefix = prefix.replace(/(?:今日|明日|明後日)(?:の)?/gu, "").trim();
    const title = `${prefix ? `${prefix}の` : ""}保険証を準備`;
    return {
      kind: role && requestSignal ? "request" : "task",
      title,
      scheduledDate,
      dueLocalTime: null,
      daypart,
      targetRole: role,
      sharedMessage: role && requestSignal
        ? `${title}をお願いできますか？`
        : null,
      subtasks: [],
      context: null,
      calendarVisibility: "hidden",
      source: "deterministic",
    };
  }

  const preparation = normalized.match(/(.{1,60}?)(?:を|の)?準備(?:し|して)/u);
  if (preparation) {
    const noun = cleanNoun(preparation[1]);
    if (noun) {
      const title = `${noun}を準備`;
      return {
        kind: role && requestSignal ? "request" : "task",
        title,
        scheduledDate,
        dueLocalTime: null,
        daypart,
        targetRole: role,
        sharedMessage: role && requestSignal
          ? `${title}をお願いできますか？`
          : null,
        subtasks: [],
        context: null,
        calendarVisibility: "hidden",
        source: "deterministic",
      };
    }
  }

  return null;
}

function parseJson(text: string): Record<string, unknown> {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i)?.[1] ?? text;
  return JSON.parse(fenced.trim()) as Record<string, unknown>;
}

/**
 * Boundary between an untrusted model response and the canonical action
 * payload.  Keep this exported so regression tests exercise the same strict
 * validation used in production without calling a provider.
 */
export function normalizeGeminiLineIntent(
  raw: string,
): Omit<LineIntent, "source"> | null {
  let p: Record<string, unknown>;
  try {
    p = parseJson(raw);
  } catch {
    return null;
  }

  if (!["task", "request", "shopping"].includes(String(p.kind))) return null;
  const title = cleanShortText(p.title, 80);
  const scheduledDate = typeof p.scheduled_date === "string"
    ? p.scheduled_date
    : "";
  if (!title || !isTokyoIsoDate(scheduledDate)) return null;

  let dueLocalTime: string | null = null;
  if (typeof p.due_local_time === "string") {
    if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(p.due_local_time)) return null;
    dueLocalTime = p.due_local_time;
  } else if (p.due_local_time !== null && p.due_local_time !== undefined) {
    return null;
  }
  const daypart =
    ["morning", "noon", "evening", "night"].includes(String(p.daypart))
      ? (p.daypart as Exclude<LineDaypart, null>)
      : null;
  const targetRole = ["papa", "mama"].includes(String(p.target_role))
    ? (p.target_role as Exclude<LineTargetRole, null>)
    : null;
  const sharedMessage = cleanShortText(p.shared_message, 240);
  const calendarVisibility = p.calendar_visibility === "special"
    ? "special"
    : "hidden";

  // A non-request must not accidentally carry an AI-written partner message.
  if (p.kind !== "request" && sharedMessage !== null) return null;

  return {
    kind: p.kind as LineIntentKind,
    title,
    scheduledDate,
    dueLocalTime,
    daypart,
    targetRole,
    sharedMessage,
    subtasks: cleanSubtasks(p.subtasks),
    context: cleanShortText(p.context, 120),
    calendarVisibility,
  };
}

async function geminiLineIntent(
  text: string,
  now: Date,
): Promise<LineIntent | null> {
  const model = Deno.env.get("GEMINI_MODEL_LINE_INTENT") ??
    Deno.env.get("GEMINI_MODEL_REWRITE") ?? "";
  if (!model) return null;
  const today = addJstDays(now, 0);
  const prompt = [
    "家庭内タスク管理LINEの自然文を、送信者が確認できる1件の安全なアクションへ構造化してください。",
    `今日(Asia/Tokyo)は ${today} です。`,
    "重要: 作業の実行日と、病院・行事などの予定日は区別する。",
    "例: 「明日11時から藤沢の皮膚科。10時には出発必要なので子供の身支度、診察カード、保険証を準備」は、",
    "title「皮膚科の準備」、scheduled_date は明日、due_local_time は「10:00」、",
    "subtasks は「子供の身支度」「診察カード」「保険証」、context は「藤沢の皮膚科 11:00」とする。",
    "予定そのものを新しいGoogle Calendar予定として作らない。入力に書かれていない事実・時刻・担当を作らない。",
    "kind は task/request/shopping のいずれか。相手に「してほしい」「お願い」など明確な依頼表現がある場合だけ request。担当名が出ただけでは request にしない。「パパのタスクとして追加」は task。",
    "target_role は papa/mama/null。嫁さん・妻・奥さんは mama。",
    "daypart は morning/noon/evening/night/null。",
    "scheduled_date は YYYY-MM-DD。明示が無い場合は今日。",
    "due_local_time は入力にある実行期限・出発時刻を HH:MM で返す。無ければ null。",
    "title は80文字以内の短い行動名。メタ文言「タスクとして追加して」は入れない。",
    "subtasks は実際にチェックできる持ち物・手順だけを最大5件。無ければ空配列。",
    "context は予定の場所・開始時刻等の短い補足だけ。無ければnull。",
    "calendar_visibility は、病院・習い事・学校/保育園行事・特別な持ち物など家族予定として見通しとGoogle Calendarに出すべき一回限りの対応だけ special。それ以外の日常タスクは hidden。タイトルの単語だけで判断せず、入力全体の意味だけで選ぶ。",
    "shared_message は request のときだけ、事実を増やさず柔らかい依頼文。それ以外null。",
    '必ずJSONのみ: {"kind":"task|request|shopping","title":"...","scheduled_date":"YYYY-MM-DD","due_local_time":"HH:MM|null","daypart":"morning|noon|evening|night|null","target_role":"papa|mama|null","shared_message":"...|null","subtasks":["..."],"context":"...|null","calendar_visibility":"special|hidden"}',
    "",
    `入力: ${JSON.stringify(text)}`,
  ].join("\n");
  try {
    const raw = await callGemini(prompt, model);
    const normalized = normalizeGeminiLineIntent(raw);
    return normalized ? { ...normalized, source: "gemini" } : null;
  } catch (error) {
    console.warn("process-line-inbox: Gemini intent extraction unavailable", {
      code: error instanceof Error ? error.message : "unknown",
    });
    return null;
  }
}

export async function extractLineIntent(
  text: string,
  now = new Date(),
): Promise<LineIntent | null> {
  if (isLineCreateStarter(text)) return null;
  // Natural language is AI-first. The deterministic parser is only a safe
  // availability fallback when the provider is unavailable or rejects output.
  return (await geminiLineIntent(text, now)) ??
    deterministicLineIntent(text, now);
}

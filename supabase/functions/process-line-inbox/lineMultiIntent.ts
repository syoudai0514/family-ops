import {
  deterministicLineIntent,
  extractLineIntent,
  type LineIntent,
  type LineIntentKind,
} from "./lineIntent.ts";

/** A review candidate stays private until the sender confirms it. */
export type LineConversationCandidate = {
  candidateId: string;
  kind: LineIntentKind | "share" | "actual";
  title: string;
  intent: LineIntent | null;
  sourceText: string;
  missingFields: string[];
};

/** Durable, sender-private payload used by the existing pending-action queue. */
export type LineMultiIntentPendingCandidate = {
  candidate_id: string;
  kind: LineConversationCandidate["kind"];
  title: string;
  source_text: string;
  status: "draft" | "cancelled";
  missing_fields: string[];
  action_type: "task_create_once" | "shopping_item_add" | "request_create" | "handover_create" | "actual_record";
  payload: Record<string, unknown>;
};

export function activeMultiIntentCandidates(
  value: unknown,
): LineMultiIntentPendingCandidate[] {
  if (!Array.isArray(value)) return [];
  return value.filter((candidate): candidate is LineMultiIntentPendingCandidate => {
    if (!candidate || typeof candidate !== "object") return false;
    const row = candidate as Record<string, unknown>;
    return typeof row.candidate_id === "string" &&
      typeof row.title === "string" &&
      row.status === "draft" &&
      Array.isArray(row.missing_fields) &&
      typeof row.action_type === "string" &&
      row.payload !== null && typeof row.payload === "object";
  });
}

function title(value: string): string {
  return value.replace(/[。！!？?]/g, "").replace(/\s+/g, " ").trim().slice(0, 80);
}

const WEEKDAY_INDEX: Record<string, number> = {
  日曜: 0, 月曜: 1, 火曜: 2, 水曜: 3, 木曜: 4, 金曜: 5, 土曜: 6,
};
const JST_OFFSET_MS = 9 * 60 * 60 * 1000;

function dateFromToken(token: string, now: Date): string {
  const shifted = new Date(now.getTime() + JST_OFFSET_MS);
  const base = new Date(Date.UTC(shifted.getUTCFullYear(), shifted.getUTCMonth(), shifted.getUTCDate()));
  let days: number;
  if (token === "今日") days = 0;
  else if (token === "明日") days = 1;
  else if (token === "明後日") days = 2;
  else {
    const target = WEEKDAY_INDEX[token];
    days = (target - base.getUTCDay() + 7) % 7;
  }
  base.setUTCDate(base.getUTCDate() + days);
  return base.toISOString().slice(0, 10);
}

function explicitDate(clause: string, now: Date): string {
  const token = clause.match(/今日|明日|明後日|[月火水木金土日]曜/u)?.[0] ?? "今日";
  return dateFromToken(token, now);
}

function explicitRole(clause: string): "papa" | "mama" | null {
  const correction = clause.match(/(?:パパ|父|お父さん|ママ|母|お母さん|嫁さん|奥さん|妻)\s*(?:じゃなくて|ではなくて|ではなく|じゃなく|の代わりに)\s*(パパ|父|お父さん|ママ|母|お母さん|嫁さん|奥さん|妻)/u);
  const token = correction?.[1] ?? clause.match(/パパ|父|お父さん|ママ|母|お母さん|嫁さん|奥さん|妻/u)?.[0] ?? null;
  if (!token) return null;
  return /^(?:パパ|父|お父さん)$/u.test(token) ? "papa" : "mama";
}

function fallbackRequestIntent(clause: string, requestTitle: string, now: Date): LineIntent {
  const role = explicitRole(clause);
  return {
    kind: "request",
    title: requestTitle,
    scheduledDate: explicitDate(clause, now),
    dueLocalTime: null,
    daypart: null,
    targetRole: role,
    sharedMessage: `${requestTitle}をお願いできますか？`,
    subtasks: [],
    context: null,
    calendarVisibility: "hidden",
    source: "deterministic",
  };
}

function clauseCandidates(clause: string, now: Date): Omit<LineConversationCandidate, "candidateId">[] {
  const parsed = deterministicLineIntent(clause, now);
  if (parsed) {
    const cleanedTitle = parsed.kind === "shopping" ? parsed.title.replace(/も$/u, "") : parsed.title;
    return [{
      kind: parsed.kind,
      title: cleanedTitle,
      intent: parsed.kind === "shopping" && cleanedTitle !== parsed.title ? { ...parsed, title: cleanedTitle } : parsed,
      sourceText: clause,
      missingFields: parsed.kind === "request" && !parsed.targetRole ? ["assignee"] : [],
    }];
  }

  const lowStock = clause.match(/^(.{1,60}?)(?:が|は)?(?:もう)?なくなりそう/u);
  if (lowStock) return [{
    kind: "shopping", title: title(lowStock[1]), intent: null, sourceText: clause,
    missingFields: [],
  }];
  const request = clause.match(/^(.{1,70}?)(?:を)?(?:お願い(?:します|したい)?|頼める[？?]?)$/u);
  if (request) {
    const requestTitle = title(request[1])
      .replace(/^(?:今日|明日|明後日|[月火水木金土日]曜)の?/u, "")
      .replace(/(?:パパ|父|お父さん|ママ|母|お母さん|嫁さん|奥さん|妻)$/u, "")
      .trim();
    const intent = fallbackRequestIntent(clause, requestTitle, now);
    return [{
      kind: "request", title: requestTitle, intent, sourceText: clause,
      missingFields: intent.targetRole ? [] : ["assignee"],
    }];
  }
  const actual = clause.match(/^(.{1,70}?)(?:を)?(?:やった|した|かけた)(?:よ|済み)?$/u);
  if (actual) return [{
    kind: "actual", title: title(actual[1]), intent: null, sourceText: clause,
    missingFields: [],
  }];
  if (/(?:水遊び|行事|変更|お知らせ|熱|咳|休み)/u.test(clause)) return [{
    kind: "share", title: title(clause), intent: null, sourceText: clause,
    missingFields: [],
  }];
  return [];
}

function splitConversation(text: string): string[] {
  return text
    // Preserve spoken/typed correction boundaries before NFKC expands `…`
    // into ASCII dots; then also handle already-expanded ellipsis forms.
    .replace(/…{2,}/g, "。")
    .normalize("NFKC")
    .replace(/\.{2,}/g, "。")
    .split(/[。！!\n]+/)
    .map((v) => v.trim())
    .filter(Boolean);
}

function correctionDate(clause: string, now: Date): string | null {
  const match = clause.match(/(?:あ[、,]?\s*)?(?:やっぱ|やっぱり|訂正(?:して)?|ではなく|じゃなくて?)\s*(今日|明日|明後日|[月火水木金土日]曜)/u);
  return match ? dateFromToken(match[1], now) : null;
}

function applyCorrection(
  candidates: Omit<LineConversationCandidate, "candidateId">[],
  clause: string,
  now: Date,
): boolean {
  const scheduledDate = correctionDate(clause, now);
  if (!scheduledDate || candidates.length === 0) return false;
  const index = candidates.length - 1;
  const previous = candidates[index];
  if (!previous.intent) return false;
  candidates[index] = {
    ...previous,
    sourceText: `${previous.sourceText} / 訂正: ${clause}`,
    intent: { ...previous.intent, scheduledDate },
  };
  return true;
}

function finalize(candidates: Omit<LineConversationCandidate, "candidateId">[]): LineConversationCandidate[] {
  return candidates.map((candidate, index) => ({ ...candidate, candidateId: `c${index + 1}` }));
}

/** Deterministic fallback and regression oracle. */
export function deterministicLineConversationCandidates(
  text: string,
  now = new Date(),
): LineConversationCandidate[] {
  const candidates: Omit<LineConversationCandidate, "candidateId">[] = [];
  for (const clause of splitConversation(text)) {
    if (applyCorrection(candidates, clause, now)) continue;
    candidates.push(...clauseCandidates(clause, now));
  }
  return finalize(candidates);
}

/**
 * PWA/LINE shared AI-first path. Each actionable clause is sent through the
 * same Gemini-backed extractor used by LINE; deterministic parsing remains an
 * availability fallback. Explicit correction clauses update the immediately
 * preceding candidate instead of becoming a bogus extra task.
 */
export async function aiFirstLineConversationCandidates(
  text: string,
  now = new Date(),
): Promise<LineConversationCandidate[]> {
  const candidates: Omit<LineConversationCandidate, "candidateId">[] = [];
  for (const clause of splitConversation(text)) {
    if (applyCorrection(candidates, clause, now)) continue;
    const parsed = await extractLineIntent(clause, now);
    if (parsed) {
      const cleanedTitle = parsed.kind === "shopping" ? parsed.title.replace(/も$/u, "") : parsed.title;
      candidates.push({
        kind: parsed.kind,
        title: cleanedTitle,
        intent: parsed.kind === "shopping" && cleanedTitle !== parsed.title ? { ...parsed, title: cleanedTitle } : parsed,
        sourceText: clause,
        missingFields: parsed.kind === "request" && !parsed.targetRole ? ["assignee"] : [],
      });
      continue;
    }
    candidates.push(...clauseCandidates(clause, now));
  }
  return finalize(candidates);
}

export function isMultiIntentMessage(candidates: LineConversationCandidate[]): boolean {
  return candidates.length > 1;
}

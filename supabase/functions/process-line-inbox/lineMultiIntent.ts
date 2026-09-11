import { callGemini } from "../_shared/gemini.ts";
import {
  deterministicLineIntent,
  normalizeGeminiLineIntent,
  type LineIntent,
  type LineIntentKind,
} from "./lineIntent.ts";

export type ConciergeDuplicateMatch = {
  entityKind: "task" | "shopping" | "request";
  entityId: string;
  expectedRevision: number;
  evidence: {
    strategy: "canonical_exact";
    matchedTitle: string;
    matchedDate: string | null;
  };
};

/** Channel-independent semantic candidate. No business mutation occurs here. */
export type LineConversationCandidate = {
  candidateId: string;
  operationId: string | null;
  kind: LineIntentKind | "share" | "actual";
  title: string;
  intent: LineIntent | null;
  sourceText: string;
  sourceSpan: { start: number; end: number } | null;
  confidence: number | null;
  ambiguousFields: string[];
  missingFields: string[];
  duplicateMatch: ConciergeDuplicateMatch | null;
};

/** Durable, sender-private payload used by the existing pending-action queue. */
export type LineMultiIntentPendingCandidate = {
  candidate_id: string;
  operation_id: string;
  kind: LineConversationCandidate["kind"];
  title: string;
  source_text: string;
  source_span: { start: number; end: number } | null;
  confidence: number | null;
  ambiguous_fields: string[];
  duplicate_match: ConciergeDuplicateMatch | null;
  duplicate_decision: "existing" | "update" | "separate" | null;
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
      typeof row.operation_id === "string" &&
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
  const roleToken = "(?:パパ|父|お父さん|ママ|母|お母さん|嫁さん|奥さん|妻)";
  const directCorrection = clause.match(
    new RegExp(`${roleToken}\\s*(?:じゃなくて|ではなくて|ではなく|じゃなく|の代わりに)\\s*(${roleToken})`, "u"),
  );
  const colloquialCorrections = [
    ...clause.matchAll(
      new RegExp(`(?:いや(?:違う)?|やっぱ(?:り)?|訂正(?:して)?)[、,\\s]*(?:相手(?:は)?[、,\\s]*)?(${roleToken})`, "gu"),
    ),
  ];
  const corrected = colloquialCorrections.at(-1)?.[1] ?? directCorrection?.[1] ?? null;
  const tokens = [...clause.matchAll(new RegExp(roleToken, "gu"))].map((match) => match[0]);
  const token = corrected ?? tokens.at(-1) ?? null;
  if (!token) return null;
  return /^(?:パパ|父|お父さん)$/u.test(token) ? "papa" : "mama";
}

function hasExplicitClock(text: string): boolean {
  return /(?:\d{1,2}時(?:\d{1,2}分|半)?|\d{1,2}:\d{2})/u.test(text);
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

function sourceSpan(raw: string, source: string, cursor = 0): { start: number; end: number } | null {
  const direct = raw.indexOf(source, cursor);
  const start = direct >= 0 ? direct : raw.indexOf(source);
  return start >= 0 ? { start, end: start + source.length } : null;
}

function clauseCandidates(clause: string, now: Date): Omit<LineConversationCandidate, "candidateId">[] {
  const parsed = deterministicLineIntent(clause, now);
  if (parsed) {
    const cleanedTitle = parsed.kind === "shopping" ? parsed.title.replace(/も$/u, "") : parsed.title;
    return [{
      operationId: null,
      kind: parsed.kind,
      title: cleanedTitle,
      intent: parsed.kind === "shopping" && cleanedTitle !== parsed.title ? { ...parsed, title: cleanedTitle } : parsed,
      sourceText: clause,
      sourceSpan: null,
      confidence: null,
      ambiguousFields: [],
      missingFields: parsed.kind === "request" && !parsed.targetRole ? ["assignee"] : [],
      duplicateMatch: null,
    }];
  }

  const lowStock = clause.match(
    /^(.{1,60}?)(?:が|は|も)?(?:もう)?(?:なくなりそう|なくなる|なくなった|残り少ない|残りわずか|もうない|ない)$/u,
  );
  if (lowStock) return [{
    operationId: null,
    kind: "shopping", title: title(lowStock[1]), intent: null, sourceText: clause,
    sourceSpan: null, confidence: null, ambiguousFields: [], missingFields: [], duplicateMatch: null,
  }];

  const tersePreparation = clause.match(
    /^(?:(?:今日|明日|明後日)(?:の)?)?(?:(?:朝|昼|夕方|夜)(?:の)?)?(.{1,60}?)準備(?:して)?$/u,
  );
  if (tersePreparation) {
    const item = title(tersePreparation[1]);
    return [{
      operationId: null,
      kind: "task",
      title: `${item}準備`,
      intent: {
        kind: "task",
        title: `${item}準備`,
        scheduledDate: explicitDate(clause, now),
        dueLocalTime: null,
        daypart: /朝/u.test(clause) ? "morning" : /昼/u.test(clause) ? "noon" : /夕方/u.test(clause) ? "evening" : /夜/u.test(clause) ? "night" : null,
        targetRole: explicitRole(clause),
        sharedMessage: null,
        subtasks: [],
        context: null,
        calendarVisibility: "hidden",
        source: "deterministic",
      },
      sourceText: clause,
      sourceSpan: null,
      confidence: null,
      ambiguousFields: [],
      missingFields: [],
      duplicateMatch: null,
    }];
  }

  const terseTask = clause.match(
    /^(?:(?:今日|明日|明後日)(?:の)?)?(?:(朝|昼|夕方|夜)(?:に|は|の)?)?(ゴミ出し)$/u,
  );
  if (terseTask) {
    const daypart = terseTask[1] === "朝" ? "morning" : terseTask[1] === "昼" ? "noon" : terseTask[1] === "夕方" ? "evening" : terseTask[1] === "夜" ? "night" : null;
    return [{
      operationId: null,
      kind: "task",
      title: terseTask[2],
      intent: {
        kind: "task",
        title: terseTask[2],
        scheduledDate: explicitDate(clause, now),
        dueLocalTime: null,
        daypart,
        targetRole: explicitRole(clause),
        sharedMessage: null,
        subtasks: [],
        context: null,
        calendarVisibility: "hidden",
        source: "deterministic",
      },
      sourceText: clause,
      sourceSpan: null,
      confidence: null,
      ambiguousFields: [],
      missingFields: [],
      duplicateMatch: null,
    }];
  }

  const pickupRole = clause.match(
    /^(?:(?:今日|明日|明後日)(?:の)?)?お?迎え(?:は|担当(?:は)?)?(パパ|父|お父さん|ママ|母|お母さん|嫁さん|奥さん|妻)$/u,
  );
  if (pickupRole) {
    const role = /^(?:パパ|父|お父さん)$/u.test(pickupRole[1]) ? "papa" : "mama";
    return [{
      operationId: null,
      kind: "task",
      title: "お迎え",
      intent: {
        kind: "task",
        title: "お迎え",
        scheduledDate: explicitDate(clause, now),
        dueLocalTime: null,
        daypart: null,
        targetRole: role,
        sharedMessage: null,
        subtasks: [],
        context: null,
        calendarVisibility: "special",
        source: "deterministic",
      },
      sourceText: clause,
      sourceSpan: null,
      confidence: null,
      ambiguousFields: [],
      missingFields: [],
      duplicateMatch: null,
    }];
  }
  const request = clause.match(/^(.{1,70}?)(?:を)?(?:お願い(?:します|したい)?|頼める[？?]?)$/u);
  if (request) {
    const requestTitle = title(request[1])
      .replace(/^(?:今日|明日|明後日|[月火水木金土日]曜)の?/u, "")
      .replace(/(?:パパ|父|お父さん|ママ|母|お母さん|嫁さん|奥さん|妻)$/u, "")
      .trim();
    const intent = fallbackRequestIntent(clause, requestTitle, now);
    return [{
      operationId: null,
      kind: "request", title: requestTitle, intent, sourceText: clause,
      sourceSpan: null, confidence: null, ambiguousFields: intent.targetRole ? [] : ["assignee"],
      missingFields: intent.targetRole ? [] : ["assignee"], duplicateMatch: null,
    }];
  }
  const actual = clause.match(/^(.{1,70}?)(?:を)?(?:やった|した|かけた)(?:よ|済み)?$/u);
  if (actual) return [{
    operationId: null,
    kind: "actual", title: title(actual[1]), intent: null, sourceText: clause,
    sourceSpan: null, confidence: null, ambiguousFields: [], missingFields: [], duplicateMatch: null,
  }];
  if (/(?:水遊び|行事|変更|お知らせ|熱|咳|休み)/u.test(clause)) return [{
    operationId: null,
    kind: "share", title: title(clause), intent: null, sourceText: clause,
    sourceSpan: null, confidence: null, ambiguousFields: [], missingFields: [], duplicateMatch: null,
  }];
  return [];
}

function splitConversation(text: string): string[] {
  return text
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

function correctionRole(clause: string): "papa" | "mama" | null {
  const match = clause.match(
    /(?:いや(?:違う)?|やっぱ(?:り)?|訂正(?:して)?)[、,\s]*(?:相手(?:は)?[、,\s]*)?(パパ|父|お父さん|ママ|母|お母さん|嫁さん|奥さん|妻)/u,
  );
  if (!match) return null;
  return /^(?:パパ|父|お父さん)$/u.test(match[1]) ? "papa" : "mama";
}

function applyRoleCorrection(
  candidates: Omit<LineConversationCandidate, "candidateId">[],
  clause: string,
): boolean {
  const role = correctionRole(clause);
  if (!role || candidates.length === 0) return false;
  const index = candidates.length - 1;
  const previous = candidates[index];
  if (!previous.intent) return false;
  candidates[index] = {
    ...previous,
    sourceText: `${previous.sourceText}、${clause}`,
    sourceSpan: null,
    intent: { ...previous.intent, targetRole: role },
  };
  return true;
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
    sourceSpan: null,
    intent: { ...previous.intent, scheduledDate },
  };
  return true;
}

function finalize(candidates: Omit<LineConversationCandidate, "candidateId">[], rawText: string): LineConversationCandidate[] {
  let cursor = 0;
  return candidates.map((candidate, index) => {
    const span = candidate.sourceSpan ?? sourceSpan(rawText, candidate.sourceText, cursor);
    if (span) cursor = span.end;
    return { ...candidate, sourceSpan: span, candidateId: `c${index + 1}` };
  });
}

function hasExplicitDateToken(text: string): boolean {
  return /今日|明日|明後日|[月火水木金土日]曜/u.test(text);
}

function commaSeparatedCandidates(
  clause: string,
  now: Date,
): Omit<LineConversationCandidate, "candidateId">[] | null {
  const parts = clause
    .split(/[、，,]+/u)
    .map((part) => part.trim())
    .filter(Boolean);
  if (parts.length < 2) return null;

  const flattened: Omit<LineConversationCandidate, "candidateId">[] = [];
  let inheritedDate: string | null = null;

  for (const part of parts) {
    if (hasExplicitDateToken(part)) inheritedDate = explicitDate(part, now);

    if (applyRoleCorrection(flattened, part)) continue;
    if (applyCorrection(flattened, part, now)) continue;

    const group = clauseCandidates(part, now);
    // Split only when every comma-delimited fragment independently carries a
    // recognized intent or correction. This avoids breaking noun lists such as
    // "身支度、診察カード、保険証を準備".
    if (group.length === 0) return null;

    for (const candidate of group) {
      if (candidate.intent && inheritedDate && !hasExplicitDateToken(part)) {
        flattened.push({
          ...candidate,
          intent: { ...candidate.intent, scheduledDate: inheritedDate },
        });
      } else {
        flattened.push(candidate);
      }
    }
  }
  return flattened.length > 1 ? flattened : null;
}

/** Deterministic availability fallback and regression oracle. */
export function deterministicLineConversationCandidates(
  text: string,
  now = new Date(),
): LineConversationCandidate[] {
  const candidates: Omit<LineConversationCandidate, "candidateId">[] = [];
  for (const clause of splitConversation(text)) {
    if (applyCorrection(candidates, clause, now)) continue;
    const commaCandidates = commaSeparatedCandidates(clause, now);
    if (commaCandidates) {
      candidates.push(...commaCandidates);
      continue;
    }
    candidates.push(...clauseCandidates(clause, now));
  }
  return finalize(candidates, text);
}

function cleanStringArray(value: unknown, max = 8): string[] {
  if (!Array.isArray(value)) return [];
  const values: string[] = [];
  for (const item of value) {
    if (typeof item !== "string") continue;
    const cleaned = item.trim().slice(0, 60);
    if (cleaned && !values.includes(cleaned)) values.push(cleaned);
    if (values.length >= max) break;
  }
  return values;
}

function parseModelJson(raw: string): Record<string, unknown> | null {
  try {
    const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i)?.[1] ?? raw;
    const parsed = JSON.parse(fenced.trim());
    return parsed && typeof parsed === "object" ? parsed as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

/** Strict boundary for the whole-utterance AI decomposition contract. */
export function normalizeSemanticDecomposition(
  raw: string,
  source: string,
): LineConversationCandidate[] {
  const parsed = parseModelJson(raw);
  const rows = parsed && Array.isArray(parsed.candidates) ? parsed.candidates : [];
  const normalized: Omit<LineConversationCandidate, "candidateId">[] = [];
  for (const value of rows.slice(0, 8)) {
    if (!value || typeof value !== "object") return [];
    const row = value as Record<string, unknown>;
    let kind = String(row.kind ?? "");
    if (!["task", "request", "shopping", "share", "actual"].includes(kind)) return [];
    let candidateTitle = typeof row.title === "string" ? title(row.title) : "";
    const sourceText = typeof row.source_text === "string" ? row.source_text.trim() : "";
    if (!candidateTitle || !sourceText || !source.includes(sourceText)) return [];

    if (kind === "shopping" && /(?:買った|購入した|注文した)(?:よ|済み)?$/u.test(sourceText)) {
      kind = "actual";
      candidateTitle = title(sourceText.replace(/^(?:今日|明日|明後日)(?:の)?/u, ""));
    }
    if (
      kind === "shopping" &&
      /(?:薬局|スーパー|コンビニ|店)(?:に)?(?:寄る|行く)$/u.test(sourceText) &&
      !/(?:買|購入|注文|なくな|残り少|もうない)/u.test(sourceText)
    ) {
      kind = "task";
      candidateTitle = title(sourceText.replace(/^帰り(?:に)?/u, ""));
    }
    const missingFields = cleanStringArray(row.missing_fields);
    const ambiguousFields = cleanStringArray(row.ambiguous_fields);
    const confidence = typeof row.confidence === "number" && row.confidence >= 0 && row.confidence <= 1
      ? row.confidence
      : null;

    let intent: LineIntent | null = null;
    if (kind === "task" || kind === "request" || kind === "shopping") {
      const intentRaw = JSON.stringify({
        kind,
        title: candidateTitle,
        scheduled_date: row.scheduled_date,
        due_local_time: row.due_local_time ?? null,
        daypart: row.daypart ?? null,
        target_role: row.target_role ?? null,
        shared_message: kind === "request" ? (row.shared_message ?? null) : null,
        subtasks: row.subtasks ?? [],
        context: row.context ?? null,
        calendar_visibility: row.calendar_visibility ?? "hidden",
      });
      const validated = normalizeGeminiLineIntent(intentRaw);
      if (!validated) return [];
      const sourceRole = explicitRole(sourceText);
      intent = {
        ...validated,
        // A role may only become canonical when the candidate's own source
        // text names it. This blocks model-invented Papa/Mama assignments.
        targetRole: sourceRole,
        // "朝/夜" may remain a daypart, but it must never silently become
        // 09:00/20:00. A concrete due time requires a concrete clock token.
        dueLocalTime: hasExplicitClock(sourceText) ? validated.dueLocalTime : null,
        source: "gemini",
      };
    }

    normalized.push({
      operationId: null,
      kind: kind as LineConversationCandidate["kind"],
      title: candidateTitle,
      intent,
      sourceText,
      sourceSpan: sourceSpan(source, sourceText),
      confidence,
      ambiguousFields,
      missingFields,
      duplicateMatch: null,
    });
  }
  return finalize(normalized, source);
}

type SemanticProvider = (text: string, now: Date) => Promise<string | null>;

async function geminiSemanticProvider(text: string, now: Date): Promise<string | null> {
  const model = Deno.env.get("GEMINI_MODEL_LINE_DECOMPOSITION") ??
    Deno.env.get("GEMINI_MODEL_LINE_INTENT") ??
    Deno.env.get("GEMINI_MODEL_REWRITE") ?? "";
  if (!model) return null;
  const today = new Date(now.getTime() + JST_OFFSET_MS).toISOString().slice(0, 10);
  const prompt = [
    "家庭内オペレーションの自然文を、意味上独立した候補へAI-firstで分解してください。",
    `今日(Asia/Tokyo)は ${today} です。`,
    "最優先: 入力にない担当・時刻・日付・理由・作業を作らない。",
    "句読点の有無、読点だけ、助詞抜け、口語、音声入力風、話題飛びでも意味で分ける。",
    "句読点が全く無くても動詞・対象・担当の切れ目から独立用件を分ける。",
    "例: 『明日ママ迎えお願い牛乳買ってゴミ出しもやる』 -> request『迎え』 + shopping『牛乳』 + task『ゴミ出し』の3候補。",
    "過去形の『買った』『注文した』はshopping予定ではなくactual。『薬局寄る』『スーパー行く』は、購入物が書かれていなければtaskであり、買う物を捏造しない。",
    "例: 『今日洗濯した食器片付けた牛乳買った』 -> actualを3候補。",
    "例: 『明日11時皮膚科10時出る保険証診察券準備して帰り薬局寄る』 -> 病院準備task + 薬局に寄るtask。薬の購入を捏造しない。",
    "同じkindが2件以上あっても勝手に統合しない。最大8件。",
    "読点・カンマでつながっていても意味が別なら必ず別候補にする。1候補のsource_textへ別intentの文言を巻き込まない。",
    "例: 『牛乳買って、明日のお迎えママお願い』 -> shopping『牛乳』 + request『お迎え』の2候補。shoppingのsource_textは『牛乳買って』だけ、requestは『明日のお迎えママお願い』だけ。",
    "例: 『洗濯したよ、牛乳なくなりそう、明日遠足だって』 -> actual『洗濯』 + shopping『牛乳』 + share『明日遠足』の3候補。",
    "ただし同一目的の『予定時刻 + 出発時刻 + 準備物』は別タスクに分割しない。準備/対応1候補にまとめ、予定時刻はcontext、出発/準備期限はdue_local_time、持ち物はsubtasksへ入れる。",
    "例: 『明日11時病院で10時出るから保険証と診察券準備』 -> task『病院の準備』1件。context='病院 11:00', due_local_time='10:00', subtasks=['保険証','診察券']。",
    "訂正は必ず元候補へ反映し、訂正文を新規候補にしない。",
    "例: 『土曜に牛乳買う。やっぱ日曜』 -> shopping 1件、scheduled_dateは日曜。source_textは訂正を含む連続原文。",
    "例: 『明日迎えママお願い。いやパパだった』 -> request 1件、target_role='papa'。source_textは訂正を含む連続原文。",
    "例: 『明日迎えはママ、いや違うパパ、牛乳も買って』 -> 迎え候補のtarget_roleはpapaへ訂正 + shopping『牛乳』。",
    "『ママに』『パパに』『迎えはママ』『相手はママ』等、役割が明記されたrequest/taskは target_role を必ず返す。",
    "役割が書かれていなければ target_role=null。requestだからといって担当を推測しない。",
    "買う/買って/買っといて/購入/注文は shopping。命令形でもrequestにしない。",
    "request は相手への明確な家事・作業依頼だけ。",
    "actual は実施済み報告、share は予定/状態/お知らせの共有。",
    "先頭に共通の日付・時間帯があり、その後に複数の用件が連続する場合、その修飾が自然に継続する候補へ引き継ぐ。途中で別の日付が出たら以降は更新する。",
    "朝/昼/夕方/夜は daypart のみ。具体時刻が書かれていない限り due_local_time=null。09:00/20:00等を推測しない。",
    "source_textは必ず入力中の連続した原文部分をそのまま返す。役割や訂正が候補の意味に必要なら、それらも含む連続範囲をsource_textにする。",
    "不明なのが1項目だけなら他の候補/項目を保持し、その項目だけmissing_fields/ambiguous_fieldsへ入れる。",
    "task/request/shoppingは scheduled_date(YYYY-MM-DD), due_local_time, daypart, target_role, shared_message, subtasks, context, calendar_visibility を返す。",
    "calendar_visibility は特別な家族予定/病院/園学校行事ならspecial、日常家事・買い物はhidden。",
    "confidenceは0〜1。",
    'JSONのみ: {"candidates":[{"kind":"task|request|shopping|share|actual","title":"...","source_text":"入力中の連続原文","scheduled_date":"YYYY-MM-DD","due_local_time":null,"daypart":null,"target_role":null,"shared_message":null,"subtasks":[],"context":null,"calendar_visibility":"hidden","missing_fields":[],"ambiguous_fields":[],"confidence":0.9}]}',
    `入力: ${JSON.stringify(text)}`,
  ].join("\n");
  try {
    return await callGemini(prompt, model);
  } catch (error) {
    console.warn("semantic decomposition unavailable", {
      code: error instanceof Error ? error.message : "unknown",
    });
    return null;
  }
}

/**
 * The one semantic interpretation entry point shared by LINE and PWA.
 * Whole-utterance AI decomposition is normal. Deterministic parsing is only
 * an availability/validation fallback and is never used as a gate before AI.
 */
export async function decomposeLineConversationCandidates(
  text: string,
  now = new Date(),
  provider: SemanticProvider = geminiSemanticProvider,
): Promise<LineConversationCandidate[]> {
  const raw = await provider(text, now);
  if (raw) {
    const candidates = normalizeSemanticDecomposition(raw, text);
    if (candidates.length > 0) return candidates;
  }
  return deterministicLineConversationCandidates(text, now);
}

export function assignCandidateOperationIds(
  candidates: LineConversationCandidate[],
  operationIdFor: (candidateId: string) => string,
): LineConversationCandidate[] {
  return candidates.map((candidate) => ({
    ...candidate,
    operationId: candidate.operationId ?? operationIdFor(candidate.candidateId),
  }));
}

export function isMultiIntentMessage(candidates: LineConversationCandidate[]): boolean {
  return candidates.length > 1;
}

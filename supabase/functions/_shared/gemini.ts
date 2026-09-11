// WP5: Gemini AI-draft flow. docs/design/v6/05_AI_GEMINI.md (the full AI
// contract), 10_WORK_PACKAGES.md WP5 ("free_lightweight parser/rewrite,
// fact/quantity/date invariant validation, manual fallback, raw never
// recipient, user-confirmed shared text").
//
// AI_MODE=free_lightweight (05_AI_GEMINI.md §3): a single lightweight
// generateContent call asking for the exact "partner rewrite contract"
// JSON shape from §4 — no multi-step pipeline, no paid-tier features. The
// deterministic invariant check below is the "two-pass validation" §5
// requires (model rewrite, then deterministic comparison). Natural-language
// LINE actions use the model first and only accept a separately validated
// structured result; a deterministic parser is an availability fallback.
//
// Absolute rule (§8): "AI失敗 -> raw textをpartnerへ送る" is forbidden. Every
// failure path here (missing API key, HTTP error, malformed JSON, failed
// invariant check) throws instead of ever returning the raw input as if it
// were a validated proposal — callers must fall back to manual entry.

const GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta/models";

export type AiDraftTargetType = "request" | "handover";

export interface AiDraftProposal {
  sharedText: string;
  warnings: string[];
}

export interface InvariantResult {
  valid: boolean;
  missingFacts: string[];
  inventedFacts: string[];
  semanticViolations: string[];
}

// ---------------------------------------------------------------------------
// Fact/quantity/date invariant validation (pure, no network) — the piece
// exercised by gemini.test.ts's 30+ golden fixtures, since a live Gemini
// call cannot run in this environment (no real GEMINI_API_KEY provisioned).
// ---------------------------------------------------------------------------

const ABSOLUTE_DATE_PATTERNS: RegExp[] = [
  /\d{4}年\d{1,2}月\d{1,2}日/g,
  /\d{1,2}月\d{1,2}日/g,
  /\d{4}-\d{2}-\d{2}/g,
  /\d{1,2}\/\d{1,2}(?:\/\d{2,4})?/g,
];

const LATIN_PROPER_NOUN_PATTERN = /\b[A-Z][a-zA-Z]{1,}\b/g;
const KATAKANA_TOKEN_PATTERN = /[ァ-ヴー]{2,}/g;

function isRepeatedMimetic(token: string): boolean {
  if (token.length < 4 || token.length % 2 !== 0) return false;
  const half = token.length / 2;
  return token.slice(0, half) === token.slice(half);
}

function normalizedUnit(unit: string): string {
  if (unit === "分間") return "分";
  if (unit === "秒間") return "秒";
  if (unit === "l") return "L";
  return unit;
}

function addQuantityFacts(text: string, facts: Set<string>): void {
  const quantity = /(\d+(?:\.\d+)?)\s?(個|本|袋|パック|枚|回|人分|人|冊|台|匹|杯|セット|kg|g|ml|L|l|円|時間|分間|秒間|秒)/g;
  for (const match of text.matchAll(quantity)) {
    facts.add(`qty:${match[1]}${normalizedUnit(match[2])}`);
  }
  // Bare "N分" is also a duration, except when it is the minute component
  // of a clock expression such as "8時20分".
  for (const match of text.matchAll(/(\d+)分(?!間)/g)) {
    const prefix = text.slice(Math.max(0, (match.index ?? 0) - 4), match.index ?? 0);
    if (/\d{1,2}時$/.test(prefix)) continue;
    facts.add(`qty:${match[1]}分`);
  }
}

function addDateFacts(text: string, facts: Set<string>): void {
  for (const pattern of ABSOLUTE_DATE_PATTERNS) {
    for (const match of text.match(pattern) ?? []) facts.add(`date:${match}`);
  }
  for (const match of text.matchAll(/([月火水木金土日])曜日?/g)) {
    facts.add(`weekday:${match[1]}`);
  }

  const relative: Array<[RegExp, string]> = [
    [/(?:今日|本日)/u, "rel:today"],
    [/明日/u, "rel:tomorrow"],
    [/明後日/u, "rel:day_after_tomorrow"],
    [/再来週/u, "rel:week_after_next"],
    [/来週/u, "rel:next_week"],
    [/今週/u, "rel:this_week"],
    [/(?:今夜|今日の夜)/u, "rel:tonight"],
    [/(?:今朝|今日の朝)/u, "rel:this_morning"],
  ];
  for (const [pattern, key] of relative) if (pattern.test(text)) facts.add(key);

  for (const match of text.matchAll(/(\d{1,2})時(?!間)(?:(\d{1,2})分)?/g)) {
    facts.add(`time:${Number(match[1])}:${String(Number(match[2] ?? "0")).padStart(2, "0")}`);
  }
  for (const match of text.matchAll(/(?:^|\D)(\d{1,2}):(\d{2})(?!\d)/g)) {
    facts.add(`time:${Number(match[1])}:${match[2]}`);
  }
}

function addIdentityFacts(text: string, facts: Set<string>): void {
  for (const match of text.matchAll(LATIN_PROPER_NOUN_PATTERN)) {
    facts.add(`latin:${match[0]}`);
  }
  for (const match of text.matchAll(KATAKANA_TOKEN_PATTERN)) {
    const token = match[0];
    if (isRepeatedMimetic(token)) continue;
    const next = text.slice((match.index ?? 0) + token.length);
    // A katakana run is only a hard identity/location fact when Japanese
    // grammar anchors it as such. Treating every katakana word as a proper
    // noun made ordinary words such as バタバタ / ギリギリ hard invariants.
    if (/^(?:で|に|へ|から|と)/u.test(next)) facts.add(`katakana:${token}`);
  }
}

// Extracts canonical hard facts rather than raw substrings. This allows safe
// paraphrases such as 今日 -> 本日 and 30分 -> 30分間 while still rejecting
// changed dates, quantities, times and anchored identities.
export function extractFacts(text: string): string[] {
  const facts = new Set<string>();
  addDateFacts(text, facts);
  addQuantityFacts(text, facts);
  addIdentityFacts(text, facts);
  return [...facts];
}

function negationFacts(text: string): Set<string> {
  const facts = new Set<string>();
  if (/(?:し|やら|行か|出さ|買わ|持た|飲ま|食べ|片付け|変更し|お願いし)なくていい/u.test(text)) {
    facts.add("neg:not_required");
  }
  if (/(?:キャンセル|取り消(?:し|して)?)/u.test(text)) facts.add("neg:cancel");
  if (/(?:そのままで|変更しないで|変えないで)/u.test(text)) facts.add("neg:keep");
  if (/不要/u.test(text)) facts.add("neg:not_required");
  return facts;
}

const GRATITUDE_APOLOGY_PATTERNS: Array<{ label: string; pattern: RegExp }> = [
  { label: "gratitude", pattern: /(?:ありがとう|感謝して|感謝です)/u },
  { label: "apology", pattern: /(?:ごめん|すみません|申し訳)/u },
];

const REASON_PATTERNS: Array<{ label: string; pattern: RegExp }> = [
  { label: "work_reason", pattern: /(?:仕事|勤務|会議|残業|出社|会社|在宅|退勤|業務|締切)/u },
  { label: "health_reason", pattern: /(?:体調|具合|発熱|熱が|頭痛|腹痛|病気|通院|腰が痛|しんど)/u },
  { label: "transport_reason", pattern: /(?:電車|遅延|渋滞|交通)/u },
];

/**
 * Deterministic post-model invariant validation.
 *
 * Hard invariants are semantic facts, not surface wording:
 * - dates / clock times / quantities / anchored identities may not disappear
 *   or be invented;
 * - explicit "do not / no longer needed / cancel / keep as-is" semantics may
 *   not flip;
 * - gratitude/apology and unrelated reason categories may not be fabricated.
 *
 * Hostile or scorekeeping language is intentionally NOT a hard fact. The
 * rewrite layer is expected to remove it.
 */
export function validateInvariant(rawText: string, proposedText: string): InvariantResult {
  const rawFacts = extractFacts(rawText);
  const proposedFacts = extractFacts(proposedText);
  const rawSet = new Set(rawFacts);
  const proposedSet = new Set(proposedFacts);
  const missingFacts = rawFacts.filter((fact) => !proposedSet.has(fact));
  const inventedFacts = proposedFacts.filter((fact) => !rawSet.has(fact));
  const semanticViolations: string[] = [];

  const rawNegation = negationFacts(rawText);
  const proposedNegation = negationFacts(proposedText);
  for (const fact of rawNegation) {
    if (!proposedNegation.has(fact)) semanticViolations.push(`negation_lost:${fact}`);
  }
  for (const fact of proposedNegation) {
    if (!rawNegation.has(fact)) semanticViolations.push(`negation_invented:${fact}`);
  }

  for (const marker of GRATITUDE_APOLOGY_PATTERNS) {
    if (marker.pattern.test(proposedText) && !marker.pattern.test(rawText)) {
      semanticViolations.push(`invented_${marker.label}`);
    }
  }

  for (const reason of REASON_PATTERNS) {
    if (reason.pattern.test(proposedText) && !reason.pattern.test(rawText)) {
      semanticViolations.push(`invented_${reason.label}`);
    }
  }

  return {
    valid: missingFacts.length === 0 && inventedFacts.length === 0 && semanticViolations.length === 0,
    missingFacts,
    inventedFacts,
    semanticViolations,
  };
}

// ---------------------------------------------------------------------------
// Gemini API call (network — not exercised by the unit tests; verifying
// this against the live API is a manual-setup item, see the WP5 report)
// ---------------------------------------------------------------------------

export async function callGemini(prompt: string, model: string): Promise<string> {
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey || apiKey.length === 0 || !model || model.length === 0) {
    throw new Error("GEMINI_NOT_CONFIGURED");
  }

  const url = `${GEMINI_API_BASE}/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      contents: [{ role: "user", parts: [{ text: prompt }] }],
      generationConfig: { temperature: 0.2, responseMimeType: "application/json" },
    }),
  });

  if (!res.ok) {
    throw new Error(`GEMINI_HTTP_${res.status}`);
  }

  const data = await res.json();
  const text = data?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (typeof text !== "string" || text.length === 0) {
    throw new Error("GEMINI_EMPTY_RESPONSE");
  }
  return text;
}

function extractJsonBlock(text: string): string {
  const fenceMatch = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  return (fenceMatch ? fenceMatch[1] : text).trim();
}

function buildPrompt(rawText: string, targetType: AiDraftTargetType): string {
  const targetLabel = targetType === "request" ? "パートナーへの依頼メッセージ" : "パートナーへの引き継ぎメモ";
  return [
    `あなたは家庭内の${targetLabel}を、相手が責められた・見下された・借りを返せと言われたと感じにくい自然な家族LINEへ整えるアシスタントです。`,
    "最優先は『本来伝えるべき用件・理由・日時・数量を保ちつつ、関係を悪化させる圧だけを落とす』ことです。",
    "以下を厳守してください:",
    "- 依頼内容、対象、日時、期限、数量、場所を変えない。『お風呂』を『お風呂の準備』に狭める等も禁止",
    "- 入力にない担当、理由、予定、対策、教訓を作らない",
    "- 依頼者自身の現在の事情・制約・体調・負荷が依頼理由なら、短く自然に残す",
    "- 相手の過去の失敗、貸し借り、比較、嫌味、皮肉、決めつけ、人格評価、説教、脅しは相手向け文面から除く",
    "- 『前回は私がやった』『いつも私ばかり』『どうせ暇』『また忘れる』『今度こそ』『普通できる』『文句言わずに』等を、丁寧な言葉へ置換して残すのも禁止",
    "- 相手への非難と依頼者自身の事情が混在する場合、非難だけ落として事情は残す",
    "- 過去の相手行動を現在の依頼の根拠として突きつけない",
    "- 将来のしつけ・改善要求を勝手に追加しない。今回の用件だけを伝える",
    "- 『ありがとう』『ごめん』等の感情表現を勝手に追加しない",
    "- 依頼者の感情を捏造しない",
    "- 否定/肯定を反転しない",
    "- request は夫婦LINEとして自然で柔らかくする。過剰敬語（『いただけますでしょうか』等）は避け、『お願いできる？』『お願いできますか？』程度を基本にする",
    "- handover は依頼文に変えず、確定済みの事実は確定済みの事実として簡潔に共有する",
    "- 曖昧な対象を勝手に具体化しない。元が『全部』なら『家事全部』などと補わない",
    "",
    "例:",
    "入力: 前は俺がやったんだから、明日の迎えくらいそっちがやってよ。",
    "request: 明日のお迎えをお願いできる？",
    "入力: 仕事で今日は余裕ないし、前も私がやったから、寝かしつけお願い。",
    "request: 今日は仕事で余裕がないので、寝かしつけをお願いできる？",
    "入力: どうせ家にいるんでしょ。明日の荷物受け取っといて。",
    "request: 明日の荷物の受け取りをお願いできる？",
    "入力: 今週ずっとバタバタでしんどい。今日は寝かしつけ代わってくれると助かる。",
    "request: 今週ずっとバタバタしていてしんどいので、今日は寝かしつけをお願いできる？",
    "",
    '- 出力は必ず次のJSON形式のみ: {"shared_text": string, "warnings": string[]}',
    "",
    "元のテキスト:",
    '"""',
    rawText,
    '"""',
  ].join("\n");
}

// One free_lightweight generateContent call, then a strict-shape parse.
// Throws (never silently falls back to raw text) on any missing config,
// network/HTTP failure, or malformed response — callers must catch this and
// surface a manual-fallback error to the client, never the raw input.
export async function proposeAiDraft(
  rawText: string,
  targetType: AiDraftTargetType,
): Promise<AiDraftProposal> {
  const model = Deno.env.get("GEMINI_MODEL_REWRITE") ?? "";
  const prompt = buildPrompt(rawText, targetType);
  const raw = await callGemini(prompt, model);

  let parsed: unknown;
  try {
    parsed = JSON.parse(extractJsonBlock(raw));
  } catch {
    throw new Error("GEMINI_INVALID_JSON");
  }

  if (
    typeof parsed !== "object" || parsed === null ||
    typeof (parsed as Record<string, unknown>).shared_text !== "string"
  ) {
    throw new Error("GEMINI_INVALID_SHAPE");
  }

  const warningsRaw = (parsed as Record<string, unknown>).warnings;
  return {
    sharedText: (parsed as Record<string, unknown>).shared_text as string,
    warnings: Array.isArray(warningsRaw)
      ? warningsRaw.filter((w): w is string => typeof w === "string")
      : [],
  };
}

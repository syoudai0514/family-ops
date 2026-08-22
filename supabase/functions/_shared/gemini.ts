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
}

// ---------------------------------------------------------------------------
// Fact/quantity/date invariant validation (pure, no network) — the piece
// exercised by gemini.test.ts's 30+ golden fixtures, since a live Gemini
// call cannot run in this environment (no real GEMINI_API_KEY provisioned).
// ---------------------------------------------------------------------------

const DATE_PATTERNS: RegExp[] = [
  /\d{4}年\d{1,2}月\d{1,2}日/g,
  /\d{1,2}月\d{1,2}日/g,
  /\d{4}-\d{2}-\d{2}/g,
  /\d{1,2}\/\d{1,2}(?:\/\d{2,4})?/g,
  /(?:月|火|水|木|金|土|日)曜日?/g,
  /(?:今日|明日|明後日|今週|来週|再来週|今夜|今朝)/g,
  /\d{1,2}時(?:\d{1,2}分)?/g,
];

const QUANTITY_PATTERN =
  /\d+(?:\.\d+)?\s?(?:個|本|袋|パック|枚|回|人分|人|冊|台|匹|杯|セット|kg|g|ml|L|l|円|時間|分間)/g;

// Proper-noun-like tokens: katakana runs (common for brand/product/place
// names in Japanese) and capitalized Latin words (e.g. imported brand
// names, English place names).
const KATAKANA_PATTERN = /[ァ-ヴー]{2,}/g;
const LATIN_PROPER_NOUN_PATTERN = /\b[A-Z][a-zA-Z]{1,}\b/g;

const FACT_PATTERNS: RegExp[] = [
  ...DATE_PATTERNS,
  QUANTITY_PATTERN,
  KATAKANA_PATTERN,
  LATIN_PROPER_NOUN_PATTERN,
];

// Extracts every date/quantity/proper-noun-like token from `text`, deduped.
// Exported for direct fixture-level testing.
export function extractFacts(text: string): string[] {
  const facts = new Set<string>();
  for (const pattern of FACT_PATTERNS) {
    const matches = text.match(pattern) ?? [];
    for (const m of matches) facts.add(m);
  }
  return [...facts];
}

// Every date/quantity/proper-noun-like token found in `rawText` must also
// appear verbatim in `proposedText` — dropped or altered (e.g. "3個" ->
// "5個": the exact substring "3個" is gone) facts both fail validation.
// Facts absent from the raw text impose no constraint (a purely stylistic
// rewrite of a fact-free sentence is always valid).
export function validateInvariant(rawText: string, proposedText: string): InvariantResult {
  const facts = extractFacts(rawText);
  const missingFacts = facts.filter((f) => !proposedText.includes(f));
  return { valid: missingFacts.length === 0, missingFacts };
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
  // Rules mirror docs/design/v6/05_AI_GEMINI.md §4's forbidden-transform list
  // verbatim (no addition of gratitude/apology, no fabricated emotion, no
  // quantity/date change, no negation flip, no change of who it's for, no
  // strengthening the original request).
  return [
    `あなたは家庭内の${targetLabel}を柔らかく言い換えるアシスタントです。`,
    "以下のルールを厳守してください:",
    "- 「ありがとう」「ごめん」等の感情表現を勝手に追加しない",
    "- 依頼者の感情を捏造しない",
    "- 数量を変更しない",
    "- 期限や日付を変更しない",
    "- 否定/肯定を反転しない",
    "- 依頼対象を変更しない",
    "- 元の要求を強めない",
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

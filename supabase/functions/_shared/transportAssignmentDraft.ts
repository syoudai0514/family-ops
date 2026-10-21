import {
  parseTransportAssignmentCorrection,
  parseTransportAssignmentText,
  type TransportAssignmentIntent,
} from "./transportAssignmentIntent.ts";

export type TransportAssignmentDraft = {
  intent: TransportAssignmentIntent;
  source: "raw" | "title";
  /** Classification input only. A title never supplies authoritative task/date context. */
  text: string | null;
  /** A generated title disagrees with the explicitly requested person. */
  targetConflict?: true;
  /** Informational only: the generic multi-intent candidate that was rejected. */
  candidateId?: string;
};

function nonblank(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function explicitlyNonDirective(text: string): boolean {
  const value = text.normalize("NFKC").trim().replace(/\s+/gu, "");
  // A generated title must not erase the user's explicit framing as a note,
  // quoted statement, question, refusal, or consultation. Unrecognized positive
  // phrasing is deliberately absent here: its title still cannot create a ToDo
  // whose only meaning is to change an existing assignment.
  return /[?？「」『』]|(?:ですか|ますか|ましたか|でしょうか|かな|だっけ|なのか)[。.!！]*$/u
    .test(value) ||
    /メモ|覚え書き|備忘|例文|文面|翻訳|引用|相談|検討|どうしよう|どうする|提案だけ|案だけ|伝えたい/u
      .test(value) ||
    /(?:変更|交代)(?:は|を)?(?:しない|しなく|するな|しません|不要)|変え(?:ない|なく|るな|ません)|(?:変更|交代)(?:は|が)?(?:不要|必要ない)|(?:変更|交代)したくない|(?:変更|交代)する必要はない/u
      .test(value);
}

/**
 * Detect generic drafts that must never create a new task/request in place of
 * changing an existing transport assignment. This does not authorize or apply a
 * change. In particular, a model title cannot choose the occurrence or its year.
 *
 * The user's explicit non-directive framing remains authoritative over a
 * misleading generated title. Other positive phrasing may be outside the small
 * directive grammar ("11/5は父が迎えに行きます"). A transport-change title is
 * then enough to reject generic confirmation, never enough to execute it.
 */
export function detectTransportAssignmentDraft(
  payload: Record<string, unknown>,
  now = new Date(),
): TransportAssignmentDraft | null {
  const raw = nonblank(payload.raw_text);
  if (raw) {
    const intent = parseTransportAssignmentText(raw, now);
    if (intent) return { intent, source: "raw", text: raw };
  }
  const title = nonblank(payload.title);
  const titleIntent = title ? parseTransportAssignmentText(title, now) : null;
  if (!title || !titleIntent) return null;
  if (!raw) return { intent: titleIntent, source: "title", text: title };
  if (explicitlyNonDirective(raw)) return null;
  const correction = parseTransportAssignmentCorrection(raw);
  if (correction && titleIntent.target !== correction.target) {
    return {
      intent: { ...titleIntent, target: null },
      source: "title",
      text: null,
      targetConflict: true,
    };
  }
  return { intent: titleIntent, source: "title", text: title };
}

function object(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

/**
 * Apply the same generic-creation guard to both single and multi-intent cards.
 * A multi card's parent text may include unrelated notes or questions, so only
 * each candidate's own source is relevant. Explicitly cancelled candidates do
 * not execute; missing or unknown metadata must not bypass classification.
 */
export function detectTransportAssignmentPending(
  actionType: string,
  payload: Record<string, unknown>,
  now = new Date(),
): TransportAssignmentDraft | null {
  if (["task_create_once", "request_create"].includes(actionType)) {
    return detectTransportAssignmentDraft(payload, now);
  }
  if (
    actionType !== "line_multi_intent_review" ||
    !Array.isArray(payload.candidates)
  ) return null;
  const nonGenericTypes = new Set([
    "shopping_item_add",
    "assignment_change_request",
    "handover_create",
    "actual_record",
  ]);
  for (const value of payload.candidates) {
    const candidate = object(value);
    if (!candidate || candidate.status === "cancelled") continue;
    if (
      typeof candidate.action_type === "string" &&
      nonGenericTypes.has(candidate.action_type)
    ) continue;
    const candidatePayload = object(candidate.payload) ?? {};
    const transport = detectTransportAssignmentDraft({
      ...candidatePayload,
      raw_text: nonblank(candidate.source_text) ??
        nonblank(candidatePayload.raw_text),
      title: nonblank(candidatePayload.title) ?? nonblank(candidate.title),
    }, now);
    if (transport) {
      const candidateId = nonblank(candidate.candidate_id);
      return candidateId ? { ...transport, candidateId } : transport;
    }
  }
  return null;
}

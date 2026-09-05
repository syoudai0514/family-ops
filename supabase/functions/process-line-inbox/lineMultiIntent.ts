import {
  deterministicLineIntent,
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

function clauseCandidates(clause: string, now: Date): Omit<LineConversationCandidate, "candidateId">[] {
  const parsed = deterministicLineIntent(clause, now);
  if (parsed) return [{ kind: parsed.kind, title: parsed.title, intent: parsed, sourceText: clause, missingFields: parsed.kind === "request" && !parsed.targetRole ? ["assignee"] : [] }];

  const lowStock = clause.match(/^(.{1,60}?)(?:が|は)?(?:もう)?なくなりそう/u);
  if (lowStock) return [{
    kind: "shopping", title: title(lowStock[1]), intent: null, sourceText: clause,
    missingFields: [],
  }];
  const request = clause.match(/^(.{1,70}?)(?:を)?(?:お願い(?:します|したい)?|頼める[？?]?)$/u);
  if (request) return [{
    kind: "request", title: title(request[1]), intent: null, sourceText: clause,
    missingFields: ["assignee"],
  }];
  const actual = clause.match(/^(.{1,70}?)(?:を)?(?:やった|した|かけた)(?:よ|済み)?$/u);
  if (actual) return [{
    kind: "actual", title: title(actual[1]), intent: null, sourceText: clause,
    missingFields: [],
  }];
  // A non-action statement is an explicit share candidate, rather than a
  // silently invented task.  The sender may deselect it in the grouped review.
  if (/(?:水遊び|行事|変更|お知らせ|熱|咳|休み)/u.test(clause)) return [{
    kind: "share", title: title(clause), intent: null, sourceText: clause,
    missingFields: [],
  }];
  return [];
}

/**
 * Deterministically preserve all visible candidates in a natural-language
 * message. Provider extraction may enrich this later, but it must never
 * collapse a message back to a single intent.
 */
export function deterministicLineConversationCandidates(
  text: string,
  now = new Date(),
): LineConversationCandidate[] {
  const clauses = text.normalize("NFKC").split(/[。！!\n]+/).map((v) => v.trim()).filter(Boolean);
  const candidates = clauses.flatMap((clause) => clauseCandidates(clause, now));
  return candidates.map((candidate, index) => ({ ...candidate, candidateId: `c${index + 1}` }));
}

export function isMultiIntentMessage(candidates: LineConversationCandidate[]): boolean {
  return candidates.length > 1;
}

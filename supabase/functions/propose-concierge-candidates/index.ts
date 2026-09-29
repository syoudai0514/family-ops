// Concierge proposal surface. Interpretation is read-only with respect to
// business objects: one channel-independent AI-first decomposition contract is
// used by PWA and LINE, then canonical DB rows are consulted only to surface a
// duplicate decision. No business row is written before human confirmation.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { attachCanonicalConciergeDuplicate } from "../_shared/conciergeDuplicateMatch.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import { jsonResponse, withUserMutationHandler } from "../_shared/handler.ts";
import { readJsonBody } from "../_shared/rpc.ts";
import { readOnlyLineIntent } from "../process-line-inbox/lineConversation.ts";
import {
  assignCandidateOperationIds,
  decomposeLineConversationCandidates,
} from "../process-line-inbox/lineMultiIntent.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { resolveHouseholdCandidate } from "../_shared/resolveHouseholdCandidate.ts";
import type { LineConversationCandidate } from "../process-line-inbox/lineMultiIntent.ts";

async function householdForActor(client: SupabaseClient, actorId: string): Promise<string> {
  const { data, error } = await client
    .from("household_members")
    .select("household_id")
    .eq("user_id", actorId)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!data?.household_id) throw new FamilyOpsError("NOT_HOUSEHOLD_MEMBER", "家庭への参加が必要です", 403);
  return String(data.household_id);
}

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const client = createServiceRoleClient();
  const householdId = await householdForActor(client, actorId);
  const override = body["candidate_override"];

  let interpreted: LineConversationCandidate[];
  if (override && typeof override === "object" && !Array.isArray(override)) {
    const row = override as Record<string, unknown>;
    const sourceText = typeof row.sourceText === "string" ? row.sourceText.trim() : "";
    const title = typeof row.title === "string" ? row.title.trim() : "";
    const kind = String(row.kind ?? "");
    if (!sourceText || !title || !["task", "request", "shopping", "share", "actual"].includes(kind)) {
      throw new FamilyOpsError("INVALID_INPUT", "candidate_override is invalid", 400);
    }
    const intent = row.intent && typeof row.intent === "object" && !Array.isArray(row.intent)
      ? row.intent as LineConversationCandidate["intent"]
      : null;
    interpreted = [{
      candidateId: typeof row.candidateId === "string" ? row.candidateId : "c1",
      operationId: typeof row.operationId === "string" ? row.operationId : null,
      kind: kind as LineConversationCandidate["kind"],
      title,
      intent,
      sourceText,
      sourceSpan: null,
      confidence: null,
      ambiguousFields: [],
      missingFields: Array.isArray(row.missingFields) ? row.missingFields.filter((value): value is string => typeof value === "string") : [],
      duplicateMatch: null,
    }];
  } else {
    const text = body["text"];
    if (typeof text !== "string" || text.trim().length === 0) {
      throw new FamilyOpsError("INVALID_INPUT", "text is required", 400);
    }
    if (text.length > 2000) {
      throw new FamilyOpsError("INVALID_INPUT", "text is too long", 400);
    }
    const readOnlyIntent = readOnlyLineIntent(text);
    if (readOnlyIntent) {
      return jsonResponse({ read_only_intent: readOnlyIntent, candidates: [], clarification: null });
    }
    interpreted = await decomposeLineConversationCandidates(text);
  }

  const matched = await Promise.all(
    interpreted.map((candidate) => attachCanonicalConciergeDuplicate(client, householdId, candidate)),
  );
  const identified = assignCandidateOperationIds(matched, () => crypto.randomUUID());
  const resolved = await Promise.all(identified.map(async (candidate) => {
    const resolvedAction = await resolveHouseholdCandidate(client, { candidate, actorId, householdId });
    const missingFields = resolvedAction?.type === "assignment_change_request"
      ? candidate.missingFields.filter((field) => field !== "assignee")
      : resolvedAction?.type === "needs_clarification"
      ? [...new Set([...candidate.missingFields, resolvedAction.field])]
      : candidate.missingFields;
    return { ...candidate, missingFields, resolvedAction };
  }));
  const clarification = resolved.find((candidate) => candidate.resolvedAction?.type === "needs_clarification")?.resolvedAction;
  return jsonResponse({
    read_only_intent: null,
    candidates: resolved,
    clarification: clarification?.type === "needs_clarification"
      ? clarification.question
      : resolved.length === 0 ? "追加・共有したい内容を、もう少し具体的に教えてください。" : null,
  });
}));

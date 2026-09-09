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

  const client = createServiceRoleClient();
  const householdId = await householdForActor(client, actorId);
  const interpreted = await decomposeLineConversationCandidates(text);
  const matched = await Promise.all(
    interpreted.map((candidate) => attachCanonicalConciergeDuplicate(client, householdId, candidate)),
  );
  // Stable identity is assigned while the candidate is still read-only and is
  // carried through review/retry. It is never minted by the commit click.
  const candidates = assignCandidateOperationIds(matched, () => crypto.randomUUID());

  return jsonResponse({
    read_only_intent: null,
    candidates,
    clarification: candidates.length === 0 ? "追加・共有したい内容を、もう少し具体的に教えてください。" : null,
  });
}));

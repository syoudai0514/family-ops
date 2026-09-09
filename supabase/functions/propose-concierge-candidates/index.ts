// Concierge proposal surface. Interpretation is read-only with respect to
// business objects: one channel-independent AI-first decomposition contract is
// used by PWA and LINE, then canonical DB rows are consulted only to surface a
// duplicate decision. No business row is written before human confirmation.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import { jsonResponse, withUserMutationHandler } from "../_shared/handler.ts";
import { readJsonBody } from "../_shared/rpc.ts";
import { readOnlyLineIntent } from "../process-line-inbox/lineConversation.ts";
import {
  assignCandidateOperationIds,
  decomposeLineConversationCandidates,
  type LineConversationCandidate,
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

function chooseUniqueTaskMatch(
  rows: Array<{ id: unknown; revision: unknown; title: unknown; scheduled_date: unknown }>,
  scheduledDate: string | undefined,
) {
  if (rows.length === 1) return rows[0];
  if (!scheduledDate) return null;
  const sameDate = rows.filter((row) => row.scheduled_date === scheduledDate);
  return sameDate.length === 1 ? sameDate[0] : null;
}

async function attachCanonicalDuplicate(
  client: SupabaseClient,
  householdId: string,
  candidate: LineConversationCandidate,
): Promise<LineConversationCandidate> {
  if (candidate.kind === "task") {
    // Exact canonical title is the duplicate key. Date is used to disambiguate
    // multiple same-title rows, but a unique same-title row remains selectable
    // even when the candidate proposes a changed date.
    const { data, error } = await client
      .from("task_instances")
      .select("id,revision,title,scheduled_date")
      .eq("household_id", householdId)
      .eq("title", candidate.title)
      .is("test_context_id", null)
      .in("status", ["todo", "in_progress"])
      .limit(5);
    if (error) throw new Error(error.message);
    const row = chooseUniqueTaskMatch(data ?? [], candidate.intent?.scheduledDate);
    if (row) {
      return {
        ...candidate,
        duplicateMatch: {
          entityKind: "task",
          entityId: String(row.id),
          expectedRevision: Number(row.revision),
          evidence: {
            strategy: "canonical_exact",
            matchedTitle: String(row.title),
            matchedDate: String(row.scheduled_date),
          },
        },
      };
    }
  }

  if (candidate.kind === "shopping") {
    const { data, error } = await client
      .from("shopping_items")
      .select("id,revision,title,due_at")
      .eq("household_id", householdId)
      .eq("title", candidate.title)
      .is("test_context_id", null)
      .in("status", ["wanted", "assigned", "ordered"])
      .limit(2);
    if (error) throw new Error(error.message);
    if (data?.length === 1) {
      const row = data[0];
      return {
        ...candidate,
        duplicateMatch: {
          entityKind: "shopping",
          entityId: String(row.id),
          expectedRevision: Number(row.revision),
          evidence: {
            strategy: "canonical_exact",
            matchedTitle: String(row.title),
            matchedDate: typeof row.due_at === "string" ? row.due_at : null,
          },
        },
      };
    }
  }

  return candidate;
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
    interpreted.map((candidate) => attachCanonicalDuplicate(client, householdId, candidate)),
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

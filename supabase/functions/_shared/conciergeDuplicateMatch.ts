import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { LineConversationCandidate } from "../process-line-inbox/lineMultiIntent.ts";

function chooseUniqueTaskMatch(
  rows: Array<{ id: unknown; revision: unknown; title: unknown; scheduled_date: unknown }>,
  scheduledDate: string | undefined,
) {
  if (rows.length === 1) return rows[0];
  if (!scheduledDate) return null;
  const sameDate = rows.filter((row) => row.scheduled_date === scheduledDate);
  return sameDate.length === 1 ? sameDate[0] : null;
}

/**
 * Read-only canonical DB duplicate resolution shared by LINE and PWA.
 * Exact title is the semantic key. A date only disambiguates multiple
 * same-title task rows; it is not required when there is one unique entity,
 * so changing a date can still update the matched entity with CAS.
 */
export async function attachCanonicalConciergeDuplicate(
  client: SupabaseClient,
  householdId: string,
  candidate: LineConversationCandidate,
): Promise<LineConversationCandidate> {
  if (candidate.kind === "task") {
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

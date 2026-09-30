// Reads what the context router needs from the database, and writes the conversation
// turns it later reads back. Every read is best effort: a failed read gives an emptier
// prompt, never an exception (the message then still gets answered).
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { loadOpenTasks, type CompletionContext } from "./lineCompletionReport.ts";
import type { RouterContext, Turn } from "./lineContextRouter.ts";

const WEEKDAYS = ["日", "月", "火", "水", "木", "金", "土"];

export function jstClock(now: Date = new Date()): { date: string; time: string; weekday: string } {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    weekday: "short",
  }).formatToParts(now);
  const get = (type: string) => parts.find((part) => part.type === type)?.value ?? "";
  const weekdayIndex = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(get("weekday"));
  const hour = get("hour") === "24" ? "00" : get("hour");
  return {
    date: `${get("year")}-${get("month")}-${get("day")}`,
    time: `${hour}:${get("minute")}`,
    weekday: WEEKDAYS[weekdayIndex] ?? "",
  };
}

const ROLE_LABEL: Record<string, string> = { papa: "パパ", mama: "ママ" };

/** Best-effort: the conversation must never fail because a turn could not be stored. */
export async function logLineTurn(
  client: SupabaseClient,
  actorId: string,
  role: "user" | "assistant",
  text: string,
): Promise<void> {
  const trimmed = text.trim();
  if (!trimmed) return;
  try {
    const { error } = await client.rpc("server_tx_log_line_turn", { p_actor_id: actorId, p_role: role, p_text: trimmed });
    if (error) console.warn("process-line-inbox: turn not stored", (error.message ?? "").slice(0, 100));
  } catch (err) {
    console.warn("process-line-inbox: turn not stored", err instanceof Error ? err.message.slice(0, 100) : "unknown");
  }
}

export async function loadRouterContext(
  client: SupabaseClient,
  completion: CompletionContext,
  pending: { action_type?: string; normalized_payload?: Record<string, unknown> } | null,
): Promise<RouterContext> {
  const { actorId, householdId } = completion;
  const empty = <T>(value: T) => (): T => value;

  const turns = await (async (): Promise<Turn[]> => {
    try {
      const { data } = await client.rpc("server_read_line_turns", { p_actor_id: actorId, p_limit: 10 });
      return (Array.isArray(data) ? data : [])
        .filter((row: Record<string, unknown>) => (row.role === "user" || row.role === "assistant") && typeof row.text === "string")
        .map((row: Record<string, unknown>) => ({ role: row.role as "user" | "assistant", text: String(row.text) }));
    } catch {
      return empty<Turn[]>([])();
    }
  })();

  const roles = new Map<string, string>();
  try {
    const { data } = await client.from("household_members").select("user_id,family_role").eq("household_id", householdId);
    for (const member of data ?? []) roles.set(member.user_id, ROLE_LABEL[member.family_role as string] ?? "家族");
  } catch { /* labels fall back to 家族 */ }
  const partner = [...roles.entries()].find(([id]) => id !== actorId)?.[1] ?? "相手";

  const shopping = await (async () => {
    try {
      const { data } = await client
        .from("shopping_items")
        .select("title,assignee_id")
        .eq("household_id", householdId)
        .is("test_context_id", null)
        .in("status", ["wanted", "assigned"])
        .order("created_at", { ascending: true })
        .limit(30);
      return (data ?? []).map((row: Record<string, unknown>) => ({
        title: String(row.title),
        who: !row.assignee_id ? null : row.assignee_id === actorId ? ("me" as const) : ("partner" as const),
      }));
    } catch {
      return [];
    }
  })();

  const myTasks = await (async () => {
    try {
      return (await loadOpenTasks(completion)).map((task) => task.title);
    } catch {
      return [] as string[];
    }
  })();

  const partnerOpenCount = await (async () => {
    try {
      const { count } = await client
        .from("task_instances")
        .select("id", { count: "exact", head: true })
        .eq("household_id", householdId)
        .eq("scheduled_date", completion.today)
        .is("test_context_id", null)
        .in("status", ["todo", "in_progress"])
        .neq("planned_assignee_id", actorId);
      return count ?? 0;
    } catch {
      return 0;
    }
  })();

  const draftTitle = typeof pending?.normalized_payload?.title === "string" ? pending.normalized_payload.title : "";
  return {
    now: jstClock(),
    me: roles.get(actorId) ?? "家族",
    partner,
    turns,
    pendingDraft: pending ? { kind: pending.action_type ?? "unknown", title: draftTitle || "（題名なし）" } : null,
    shopping,
    myTasks,
    partnerOpenCount,
  };
}

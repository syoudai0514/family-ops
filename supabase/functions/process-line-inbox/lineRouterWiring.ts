// Reads the household snapshot the understanding step needs, and writes the conversation
// turns it later reads back. Every read is best effort: a failed read gives an emptier
// snapshot, never an exception (the message still gets answered).
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { Daypart, Snapshot, SnapshotDraft, SnapshotShopping, SnapshotTask, SnapshotTransport, Turn } from "./lineUnderstand.ts";

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

function jstTime(iso: unknown): string | null {
  if (typeof iso !== "string" || !iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return new Intl.DateTimeFormat("ja-JP", { timeZone: "Asia/Tokyo", hour: "2-digit", minute: "2-digit", hour12: false }).format(d);
}

const ROLE_LABEL: Record<string, string> = { papa: "パパ", mama: "ママ" };

function addDays(isoDate: string, days: number): string {
  const d = new Date(`${isoDate}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

const DRAFT_KIND: Record<string, string> = { request_create: "request", shopping_item_add: "shopping", task_create_once: "task" };

/** The waiting draft with its fields, so an edit can keep what is already there. */
export function describePendingDraft(
  pending: { action_type?: string; normalized_payload?: Record<string, unknown> } | null,
  actorId: string,
): SnapshotDraft | null {
  if (!pending) return null;
  const p = pending.normalized_payload ?? {};
  const s = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : null);
  const kind = p.explicit_kind === "event" || p.calendar_visibility === "special"
    ? "event"
    : DRAFT_KIND[pending.action_type ?? ""] ?? pending.action_type ?? "unknown";
  const whoId = s(p.recipient_user_id) ?? s(p.planned_assignee_user_id) ?? s(p.assignee_user_id);
  const daypart = (["morning", "noon", "evening", "night"] as const).find((d) => d === p.daypart) ?? null;
  return {
    kind,
    title: s(p.title) ?? "（題名なし）",
    date: s(p.scheduled_date),
    time: s(p.due_local_time),
    daypart: daypart as Daypart | null,
    who: whoId ? (whoId === actorId ? "me" : "partner") : null,
  };
}

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

/** The AI-first switch (private.line_ai_settings). Any failure reads as "off". */
export async function understandEnabled(client: SupabaseClient): Promise<boolean> {
  try {
    const { data, error } = await client.rpc("server_read_line_understand_enabled");
    return !error && data === true;
  } catch {
    return false;
  }
}

/** Asks the shared per-minute Gemini budget for one call. Any failure reads as "no". */
export async function reserveAiCall(client: SupabaseClient): Promise<boolean> {
  try {
    const { data, error } = await client.rpc("server_tx_reserve_ai_call");
    return !error && data === true;
  } catch {
    return false;
  }
}

async function safe<T>(fallback: T, read: () => Promise<T>): Promise<T> {
  try {
    return await read();
  } catch {
    return fallback;
  }
}

export async function loadSnapshot(
  client: SupabaseClient,
  opts: {
    actorId: string;
    householdId: string;
    today: string;
    pending: { action_type?: string; normalized_payload?: Record<string, unknown> } | null;
  },
): Promise<Snapshot> {
  const { actorId, householdId, today } = opts;

  const tomorrow = addDays(today, 1);
  const [turns, members, taskRows, shopRows, children, notes, transportRows] = await Promise.all([
    safe<Turn[]>([], async () => {
      const { data } = await client.rpc("server_read_line_turns", { p_actor_id: actorId, p_limit: 12 });
      return (Array.isArray(data) ? data : [])
        .filter((row: Record<string, unknown>) => (row.role === "user" || row.role === "assistant") && typeof row.text === "string")
        .map((row: Record<string, unknown>) => ({ role: row.role as "user" | "assistant", text: String(row.text) }));
    }),
    safe<Array<{ user_id: string; family_role: string | null }>>([], async () => {
      const { data } = await client.from("household_members").select("user_id,family_role").eq("household_id", householdId);
      return data ?? [];
    }),
    safe<Array<Record<string, unknown>>>([], async () => {
      const { data } = await client
        .from("task_instances")
        .select("id,title,status,planned_assignee_id,assignment_mode,due_at,task_definition_id,routine_phase")
        .eq("household_id", householdId)
        .eq("scheduled_date", today)
        .is("test_context_id", null)
        .in("status", ["todo", "in_progress", "completed"])
        .order("due_at", { ascending: true, nullsFirst: false })
        .limit(60);
      return data ?? [];
    }),
    safe<Array<Record<string, unknown>>>([], async () => {
      const { data } = await client
        .from("shopping_items")
        .select("id,title,assignee_id,revision")
        .eq("household_id", householdId)
        .is("test_context_id", null)
        .in("status", ["wanted", "assigned"])
        .order("created_at", { ascending: true })
        .limit(30);
      return data ?? [];
    }),
    safe<Snapshot["children"]>([], async () => {
      const { data } = await client
        .from("child_school_contexts")
        .select("school_display_name,class_display_name,family_children(display_name)")
        .eq("household_id", householdId)
        .eq("active", true);
      return (data ?? []).map((row: Record<string, unknown>) => ({
        name: String((row.family_children as { display_name?: string } | null)?.display_name ?? "子ども"),
        school: String(row.school_display_name ?? ""),
        className: typeof row.class_display_name === "string" ? row.class_display_name : null,
      }));
    }),
    safe<string[]>([], async () => {
      const { data } = await client
        .from("handovers")
        .select("shared_text")
        .eq("household_id", householdId)
        .eq("status", "active")
        .order("created_at", { ascending: false })
        .limit(10);
      return (data ?? []).map((row: Record<string, unknown>) => String(row.shared_text ?? "").slice(0, 120)).filter(Boolean);
    }),
    // Today's and tomorrow's dropoff / pickup: "朝担当の人" means tomorrow's dropoff person.
    safe<Array<Record<string, unknown>>>([], async () => {
      const { data: defs } = await client
        .from("task_definitions")
        .select("id,code")
        .eq("household_id", householdId)
        .in("code", ["dropoff", "pickup"]);
      const codeById = new Map((defs ?? []).map((row: Record<string, unknown>) => [String(row.id), String(row.code)]));
      if (!codeById.size) return [];
      const { data } = await client
        .from("task_instances")
        .select("scheduled_date,planned_assignee_id,due_at,task_definition_id,updated_at")
        .eq("household_id", householdId)
        .in("task_definition_id", [...codeById.keys()])
        .in("scheduled_date", [today, tomorrow])
        .is("test_context_id", null)
        .neq("status", "cancelled")
        .order("updated_at", { ascending: true });
      return (data ?? []).map((row: Record<string, unknown>) => ({ ...row, code: codeById.get(String(row.task_definition_id)) }));
    }),
  ]);

  const codes = await safe(new Map<string, string>(), async () => {
    const ids = [...new Set(taskRows.map((t) => t.task_definition_id).filter((id): id is string => typeof id === "string"))];
    if (!ids.length) return new Map<string, string>();
    const { data } = await client.from("task_definitions").select("id,code").in("id", ids);
    return new Map((data ?? []).map((row: Record<string, unknown>) => [String(row.id), String(row.code ?? "")]));
  });

  const labels = new Map(members.map((m) => [m.user_id, ROLE_LABEL[m.family_role ?? ""] ?? "家族"]));
  const partner = members.find((m) => m.user_id !== actorId);

  const tasks: SnapshotTask[] = taskRows.map((row, index) => ({
    ref: `t${index + 1}`,
    id: String(row.id),
    title: String(row.title ?? ""),
    who: row.assignment_mode === "anyone"
      ? "anyone"
      : !row.planned_assignee_id ? null : row.planned_assignee_id === actorId ? "me" : "partner",
    due: jstTime(row.due_at),
    status: row.status === "completed" ? "done" : "todo",
    code: typeof row.task_definition_id === "string" ? codes.get(row.task_definition_id) ?? null : null,
    phase: typeof row.routine_phase === "string" ? row.routine_phase : null,
  }));
  const shopping: SnapshotShopping[] = shopRows.map((row, index) => ({
    ref: `s${index + 1}`,
    id: String(row.id),
    title: String(row.title ?? ""),
    who: !row.assignee_id ? null : row.assignee_id === actorId ? "me" : "partner",
    revision: Number(row.revision ?? 1),
  }));

  const transport: SnapshotTransport[] = [today, tomorrow].map((date) => {
    const slot = (code: string) => {
      // Latest row wins (rows are oldest first), as in the calendar's transport title.
      const row = transportRows.filter((r) => r.scheduled_date === date && r.code === code).at(-1);
      if (!row) return null;
      const who = !row.planned_assignee_id ? null : row.planned_assignee_id === actorId ? "me" as const : "partner" as const;
      return { who, time: jstTime(row.due_at) };
    };
    return { date, dropoff: slot("dropoff"), pickup: slot("pickup") };
  });
  return {
    now: jstClock(),
    me: labels.get(actorId) ?? "家族",
    partner: partner ? labels.get(partner.user_id) ?? "相手" : "相手",
    children,
    turns,
    pendingDraft: describePendingDraft(opts.pending, actorId),
    tasks,
    shopping,
    sharedNotes: notes,
    transport,
  };
}

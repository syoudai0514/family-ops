import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { CompactScheduleEntry } from "./lineConversation.ts";
import { buildScheduleSummaryFlex } from "./lineUxBuilders.ts";

import { LINE_SCHEDULE_PAGE_SIZE, parseLineSchedulePage, scheduleRangeTitle } from "./lineSchedulePage.ts";
export { parseLineSchedulePage } from "./lineSchedulePage.ts";

/** Each page is freshly read with the resolved LINE actor, including old buttons. */
export async function loadLineSchedulePage(opts: {
  client: SupabaseClient;
  actorId: string;
  householdId: string;
  startDate: string;
  endDate: string;
  page?: number;
  appBaseUrl: string;
  title?: string;
}): Promise<{ text: string; message: Record<string, unknown> }> {
  const range = parseLineSchedulePage({
    action: "schedule_page", start: opts.startDate, end: opts.endDate, page: String(opts.page ?? 0),
  });
  if (!range) throw new Error("INVALID_LINE_SCHEDULE_RANGE");
  const { data, error } = await opts.client.rpc("server_tx_get_week_schedule", {
    p_actor_id: opts.actorId, p_start_date: range.startDate, p_end_date: range.endDate,
  });
  if (error) throw new Error(error.message);
  const { data: members, error: memberError } = await opts.client.from("household_members")
    .select("user_id,family_role").eq("household_id", opts.householdId);
  if (memberError) throw new Error(memberError.message);
  const roles = new Map<string, string>();
  for (const member of members ?? []) {
    if (member.family_role === "papa") roles.set(member.user_id, "パパ");
    if (member.family_role === "mama") roles.set(member.user_id, "ママ");
  }
  const schedule = (data ?? {}) as {
    assignments?: Array<{ title?: string; display_title?: string | null; due_at?: string | null; planned_assignee_id?: string | null; has_conflict?: boolean }>;
    occurrences?: Array<{ title?: string; starts_at?: string | null }>;
  };
  const entries: CompactScheduleEntry[] = [
    ...(schedule.assignments ?? []).map((entry) => ({
      title: entry.display_title || entry.title || "タスク",
      startsAt: entry.due_at ?? null,
      roleLabel: entry.planned_assignee_id ? roles.get(entry.planned_assignee_id) ?? null : null,
      conflict: Boolean(entry.has_conflict),
    })),
    ...(schedule.occurrences ?? []).map((entry) => ({ title: entry.title || "Google Calendar予定", startsAt: entry.starts_at ?? null })),
  ].sort((a: CompactScheduleEntry, b: CompactScheduleEntry) => (a.startsAt ?? "").localeCompare(b.startsAt ?? "")
    || a.title.localeCompare(b.title, "ja") || (a.roleLabel ?? "").localeCompare(b.roleLabel ?? ""));
  const title = opts.title ?? scheduleRangeTitle(range.startDate, range.endDate);
  const page = Math.min(range.page, Math.max(0, Math.ceil(entries.length / LINE_SCHEDULE_PAGE_SIZE) - 1));
  const shown = entries.slice(page * LINE_SCHEDULE_PAGE_SIZE, (page + 1) * LINE_SCHEDULE_PAGE_SIZE);
  // The plain-text fallback and rich card describe the same page; neither loses
  // the original range if delivery falls back from Reply to the durable outbox.
  const lines = shown.map((entry) => {
    const date = entry.startsAt ? new Date(entry.startsAt) : null;
    const when = date && Number.isFinite(date.getTime())
      ? new Intl.DateTimeFormat("ja-JP", { timeZone: "Asia/Tokyo", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false }).format(date)
      : "終日";
    return `${when} ${entry.title}${entry.roleLabel ? `（${entry.roleLabel}）` : ""}${entry.conflict ? " ⚠️" : ""}`;
  });
  const pageCount = Math.max(1, Math.ceil(entries.length / LINE_SCHEDULE_PAGE_SIZE));
  const text = `${title}\n${page + 1}/${pageCount}ページ・最新の予定\n\n${lines.length ? lines.join("\n") : "予定はありません。"}`;
  return {
    text,
    message: buildScheduleSummaryFlex(title, entries, opts.appBaseUrl, { ...range, page }),
  };
}

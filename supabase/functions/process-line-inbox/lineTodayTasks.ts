// "今日のタスク" on LINE: every one of the sender's tasks, nothing folded into "ほか N件".
// Owner 2026-10-07: 「今日のタスクって言ったら、その他とかなしで全部書いてね。相手のは
// しょうりゃくしていいから。」 The daily brief lists only open tasks and folds the rest,
// so finished ones vanished and the list read as if things were missing. Here the
// sender's tasks are all listed (done ✓, できなかった −, open ・) by time of day; the
// partner's are summarised. The brief's other sections (予定・引き継ぎ・コドモン・買い物
// ...) are kept as they are.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export interface TodayTaskRow {
  title: string;
  status: string;
  outcome_reason?: string | null;
  routine_phase?: string | null;
  due_at?: string | null;
  planned_assignee_id?: string | null;
  assignment_mode?: string | null;
  /** "optional": 余裕があれば (e.g. 掃除 -- the Roomba does it). Never counted as left to do. */
  expectation?: string | null;
}

const PHASES: Array<{ label: string; match: (phase: string | null | undefined) => boolean }> = [
  { label: "朝", match: (p) => p === "morning" },
  { label: "日中", match: (p) => p !== "morning" && p !== "evening" && p !== "night" },
  { label: "夜", match: (p) => p === "evening" || p === "night" },
];

/** Sections of the brief that list tasks; they are replaced by the full list. */
const TASK_SECTIONS = /^(?:朝やること|日中にやること|夜にやること|今やること|相手の今日)$/u;

function jstClock(iso: string | null | undefined): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const j = new Date(d.getTime() + 9 * 3600_000);
  return `${j.getUTCHours()}:${String(j.getUTCMinutes()).padStart(2, "0")}`;
}

function shown(row: TodayTaskRow): boolean {
  if (row.status === "cancelled") return false;
  if (row.status === "skipped") return row.outcome_reason === "could_not_do";
  return true;
}

function mark(row: TodayTaskRow, quiet: boolean): string {
  if (row.status === "completed") return "✓";
  if (row.status === "skipped") return "−";
  // 余裕があれば is not left-over work: a lighter dot than the "・" of a to-do.
  return quiet ? "◦" : "・";
}

function line(row: TodayTaskRow, note = "", quiet = false): string {
  const time = jstClock(row.due_at);
  const tail = row.status === "skipped" ? "（できなかった）" : note;
  return `${mark(row, quiet)} ${time ? `${time} ` : ""}${row.title}${tail}`;
}

function byTime(a: TodayTaskRow, b: TodayTaskRow): number {
  return (a.due_at ?? "9999").localeCompare(b.due_at ?? "9999");
}

export function formatTodayTasks(rows: TodayTaskRow[], actorId: string, meLabel: string, partnerLabel: string, isToday = true): string {
  const visible = rows.filter(shown);
  const isOptional = (r: TodayTaskRow) => r.expectation === "optional";
  const mineAll = visible.filter((r) =>
    r.assignment_mode === "anyone" || !r.planned_assignee_id || r.planned_assignee_id === actorId
  );
  const mine = mineAll.filter((r) => !isOptional(r));
  const mineOptional = mineAll.filter(isOptional);
  const theirs = visible.filter((r) => !mineAll.includes(r) && !isOptional(r));
  const open = (list: TodayTaskRow[]) => list.filter((r) => r.status === "todo" || r.status === "in_progress");

  const lines: string[] = [];
  const myOpen = open(mine).length;
  lines.push(`${meLabel}のタスク（${mine.length}件・残り${myOpen}）`);
  if (mine.length === 0) lines.push("・今日の担当はありません");
  for (const phase of PHASES) {
    const list = mine.filter((r) => phase.match(r.routine_phase)).sort(byTime);
    if (!list.length) continue;
    lines.push("", phase.label);
    for (const r of list) {
      const note = r.assignment_mode === "anyone" ? "（誰でもOK）" : !r.planned_assignee_id ? "（担当未定）" : "";
      lines.push(line(r, note));
    }
  }
  // Not required: shown so it can be recorded, never counted as left.
  if (mineOptional.length) {
    lines.push("", "余裕があれば");
    for (const r of mineOptional.sort(byTime)) lines.push(line(r, "", true));
  }

  const theirOpen = open(theirs).sort(byTime);
  lines.push("", `${partnerLabel}の${isToday ? "今日" : "分"}（残り${theirOpen.length}件・済み${theirs.length - theirOpen.length}件）`);
  if (theirOpen.length) {
    const names = theirOpen.slice(0, 3).map((r) => r.title);
    lines.push(`・${names.join("、")}${theirOpen.length > 3 ? ` ほか${theirOpen.length - 3}件` : ""}`);
  }
  return lines.join("\n");
}

/** The brief with its task sections replaced by `taskBlock` (put where the first one was). */
export function mergeTodayBrief(brief: string, taskBlock: string): string {
  const sections = brief.split(/\n{2,}/u);
  const out: string[] = [];
  let placed = false;
  for (const section of sections) {
    const heading = section.split("\n", 1)[0].trim();
    if (TASK_SECTIONS.test(heading)) {
      if (!placed) out.push(taskBlock);
      placed = true;
      continue;
    }
    out.push(section);
  }
  if (!placed) out.splice(Math.min(1, out.length), 0, taskBlock);
  return out.join("\n\n");
}

function roleLabel(role: unknown, fallback: string): string {
  return role === "papa" ? "パパ" : role === "mama" ? "ママ" : fallback;
}

/** Loads today's tasks for the household and formats them; null when the read fails. */
export async function loadTodayTaskBlock(
  client: SupabaseClient,
  householdId: string,
  actorId: string,
  today: string,
  isToday = true,
): Promise<string | null> {
  const [tasks, members] = await Promise.all([
    client.from("task_instances")
      .select("title,status,outcome_reason,routine_phase,due_at,planned_assignee_id,assignment_mode,expectation")
      .eq("household_id", householdId)
      .eq("scheduled_date", today)
      .is("test_context_id", null)
      .in("status", ["todo", "in_progress", "completed", "skipped"])
      .limit(120),
    client.from("household_members")
      .select("user_id,family_role")
      .eq("household_id", householdId),
  ]);
  if (tasks.error || !tasks.data) return null;
  const memberRows = (members.data ?? []) as Array<{ user_id: string; family_role: string | null }>;
  const me = memberRows.find((m) => m.user_id === actorId);
  const partner = memberRows.find((m) => m.user_id !== actorId);
  return formatTodayTasks(
    tasks.data as TodayTaskRow[],
    actorId,
    roleLabel(me?.family_role, "自分"),
    roleLabel(partner?.family_role, "相手"),
    isToday,
  );
}

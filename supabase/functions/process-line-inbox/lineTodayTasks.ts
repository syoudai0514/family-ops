// "今日のタスク" on LINE: every one of the sender's tasks, nothing folded into "ほか N件".
// Owner 2026-10-07: 「今日のタスクって言ったら、その他とかなしで全部書いてね。相手のは
// しょうりゃくしていいから。」 The daily brief lists only open tasks and folds the rest,
// so finished ones vanished and the list read as if things were missing. Here the
// sender's tasks are all listed (done ✓, できなかった −, open ・) by time of day; the
// partner's ordinary work is not summarised. The brief's other sections (予定・引き継ぎ・コドモン・買い物
// ...) are kept as they are.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export interface TodayTaskRow {
  title: string;
  display_title?: string | null;
  responsibility_hint?: string | null;
  status: string;
  outcome_reason?: string | null;
  routine_phase?: string | null;
  due_at?: string | null;
  planned_assignee_id?: string | null;
  assignment_mode?: string | null;
  active_claimant_user_id?: string | null;
  active_claimant_label?: string | null;
  /** "optional": 余裕があれば (e.g. 掃除 -- the Roomba does it). Never counted as left to do. */
  expectation?: string | null;
  task_code?: string | null;
  task_kind?: string | null;
  assignment_confirmed?: boolean | null;
  assigned_label?: string | null;
}

const PHASES: Array<{ label: string; match: (phase: string | null | undefined) => boolean }> = [
  { label: "朝", match: (p) => p === "morning" },
  { label: "日中", match: (p) => p !== "morning" && p !== "evening" && p !== "night" },
  { label: "夜", match: (p) => p === "evening" || p === "night" },
];

/** Sections of the brief that list tasks; they are replaced by the full list. */
const TASK_SECTIONS = /^(?:朝やること|朝の残り|日中にやること|日中の残り|夜にやること|今やること|このあと（夜）|まだ残っていること|相手の今日|相手の担当で確認したいこと|家族が対応中|今日の送り迎え|余裕があれば|先に家を出る人|2人で分担（誰でもOK）|⭐ 今日、忘れずに|⭐ 今日だけの予定)$/u;
const PARTNER_WORK_SECTIONS = /^(?:相手の今日|相手の担当で確認したいこと)$/u;

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
  const tail = row.status === "skipped" ? "（今日はなし・実施せず）" : note;
  return `${mark(row, quiet)} ${time ? `${time} ` : ""}${row.display_title || row.title}${tail}`;
}

function byTime(a: TodayTaskRow, b: TodayTaskRow): number {
  return (a.due_at ?? "9999").localeCompare(b.due_at ?? "9999");
}

export function formatTodayTasks(rows: TodayTaskRow[], actorId: string, meLabel: string, partnerLabel: string, _isToday = true): string {
  const visible = rows.filter(shown);
  const isOptional = (r: TodayTaskRow) => r.expectation === "optional";
  const isShared = (r: TodayTaskRow) => r.assignment_mode === "anyone" && !r.active_claimant_user_id;
  const mineAll = visible.filter((r) => r.assignment_mode === "anyone"
    ? r.active_claimant_user_id === actorId
    : !r.planned_assignee_id || (r.planned_assignee_id === actorId && r.assignment_confirmed !== false));
  const mine = mineAll.filter((r) => !isOptional(r));
  const shared = visible.filter((r) => isShared(r) && !isOptional(r));
  const mineOptional = visible.filter((r) => isOptional(r) && (mineAll.includes(r) || isShared(r)));
  const theirs = visible.filter((r) => !mineAll.includes(r) && !isShared(r) && !isOptional(r));
  const open = (list: TodayTaskRow[]) => list.filter((r) => r.status === "todo" || r.status === "in_progress");

  const lines: string[] = [];
  const myOpen = open(mine).length;
  lines.push(`${meLabel}の担当（${mine.length}件・残り${myOpen}件）`);
  if (mine.length === 0) lines.push("・今日の担当はありません");
  for (const phase of PHASES) {
    const list = mine.filter((r) => phase.match(r.routine_phase)).sort(byTime);
    if (!list.length) continue;
    lines.push("", phase.label);
    for (const r of list) {
      const note = r.active_claimant_user_id ? `（${r.active_claimant_label || meLabel}対応中）`
        : !r.planned_assignee_id ? "（担当未定）" : "";
      lines.push(line(r, note));
    }
  }
  for (const instruction of ["先に家を出る人", "2人で分担（誰でもOK）"]) {
    const list = shared.filter((r) => (r.responsibility_hint || "2人で分担（誰でもOK）") === instruction);
    if (!list.length) continue;
    lines.push("", instruction);
    for (const phase of PHASES) {
      const phaseRows = list.filter((r) => phase.match(r.routine_phase)).sort(byTime);
      if (!phaseRows.length) continue;
      lines.push(phase.label);
      for (const r of phaseRows) lines.push(line(r));
    }
  }
  // Not required: shown so it can be recorded, never counted as left.
  if (mineOptional.length) {
    lines.push("", "余裕があれば");
    for (const r of mineOptional.sort(byTime)) lines.push(line(r, "", true));
  }

  const transport = open(theirs).filter((r) => r.task_kind === "transport" || ["dropoff", "pickup"].includes(r.task_code ?? "")).sort(byTime);
  if (transport.length) {
    lines.push("", "送り迎え");
    for (const r of transport) lines.push(line(r, r.assignment_confirmed === true
      ? `（${r.assigned_label || partnerLabel}）` : "（担当は未確認）"));
  }
  // A shared task already taken by someone else is coordination, not an
  // inventory of their assigned work; showing it prevents duplicate work.
  const sharedTaken = visible.filter((r) => r.assignment_mode === "anyone" && r.active_claimant_user_id && r.active_claimant_user_id !== actorId
    && (r.status === "todo" || r.status === "in_progress")).sort(byTime);
  if (sharedTaken.length) {
    lines.push("", "家族が対応中");
    for (const r of sharedTaken) lines.push(line(r, `（${r.active_claimant_label || partnerLabel}対応中）`, isOptional(r)));
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

/** A failed task read must not put the old partner-work summary back. */
export function hidePartnerWorkSections(brief: string): string {
  return brief.split(/\n{2,}/u)
    .filter((section) => !PARTNER_WORK_SECTIONS.test(section.split("\n", 1)[0].trim()))
    .join("\n\n");
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
    client.rpc("server_read_line_tasks_display", { p_actor_id: actorId, p_local_date: today }),
    client.from("household_members")
      .select("user_id,family_role")
      .eq("household_id", householdId),
  ]);
  if (tasks.error || !tasks.data) return null;
  const memberRows = (members.data ?? []) as Array<{ user_id: string; family_role: string | null }>;
  const me = memberRows.find((m) => m.user_id === actorId);
  const partner = memberRows.find((m) => m.user_id !== actorId);
  const displayRows = (tasks.data as TodayTaskRow[]).map((task) => ({
    ...task,
    assigned_label: roleLabel(memberRows.find((member) => member.user_id === task.planned_assignee_id)?.family_role, "家族"),
  }));
  return formatTodayTasks(
    displayRows,
    actorId,
    roleLabel(me?.family_role, "自分"),
    roleLabel(partner?.family_role, "相手"),
    isToday,
  );
}

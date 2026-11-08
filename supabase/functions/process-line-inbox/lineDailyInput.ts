import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";
import type { LineMustCompleteContext } from "./lineMustComplete.ts";

type Row = Record<string, unknown>;
const PAGE_SIZE = 6;
const say = (label: string, text = label): LineQuickReplyAction => ({ type: "message", label, text });
function button(label: string, action: string, fields: Record<string, string>): LineQuickReplyAction {
  return { type: "postback", label, displayText: label, data: new URLSearchParams({ action, ...fields }).toString() };
}
async function operationId(ctx: LineMustCompleteContext, fields: Record<string, string>): Promise<string> {
  // One displayed action is one operation even if its result is checked by a
  // later webhook event. Payload changes require a new task revision/card.
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(
    ["line-daily-input", ctx.actorId, fields.action, fields.day, fields.task_id, fields.revision, fields.codmon_sent ?? "false"].join("|"),
  )));
  const hex = [...digest.slice(0, 16)].map((v) => v.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
export function inputDates(now = new Date()): { today: string; yesterday: string } {
  const today = new Date(now.getTime() + 9 * 3600_000).toISOString().slice(0, 10);
  return { today, yesterday: new Date(Date.parse(today) - 86400_000).toISOString().slice(0, 10) };
}
function rows(value: unknown): Row[] {
  return Array.isArray(value) ? value.filter((v): v is Row => !!v && typeof v === "object" && !Array.isArray(v)) : [];
}
function choices(): LineQuickReplyAction[] {
  const { today, yesterday } = inputDates();
  return [button("朝の入力", "mc_input_open", { day: today, phase: "morning" }),
    button("夜の入力", "mc_input_open", { day: today, phase: "evening" }),
    button("昨日分・訂正", "mc_input_tasks", { day: yesterday, page: "0" }),
    button("今日分・訂正", "mc_input_tasks", { day: today, page: "0" }),
    say("予定外の実績", "予定外の実績を入力")];
}
function sessionLabel(type: unknown): string {
  return ({ dropoff: "朝・送り担当の作業", pickup: "夜・お迎え担当の作業", nonpickup_evening: "夜・お迎え以外の作業" } as Record<string, string>)[String(type)] ?? "家事の記録";
}
function validDay(day: string): boolean {
  const dates = inputDates();
  return day === dates.today || day === dates.yesterday;
}

/** Select only a session returned as actionable for the resolved actor today. */
export async function openDailyInput(ctx: LineMustCompleteContext, phase?: string, sessionId?: string): Promise<void> {
  const { data, error } = await ctx.client.rpc("server_read_current_routine_sessions", { p_actor_id: ctx.actorId });
  if (error) {
    await ctx.reply("入力する作業を読み込めませんでした。もう一度開いてください。", [say("入力")]);
    return;
  }
  const root = data as Row | null;
  const day = typeof root?.local_date === "string" ? root.local_date : inputDates().today;
  const sessions = rows(root?.sessions ?? data).filter((row) => row.can_act !== false && row.status !== "submitted" && row.status !== "superseded");
  const preferred = phase ?? (new Date(Date.now() + 9 * 3600_000).getUTCHours() < 12 ? "morning" : "evening");
  const matches = sessions.filter((row) => preferred === "morning" ? row.session_type === "dropoff" : row.session_type !== "dropoff");
  const session = sessionId ? sessions.find((row) => (row.session_id ?? row.id) === sessionId)
    : phase ? matches[0] : matches[0] ?? sessions[0];
  if (!session) {
    await ctx.reply(`${day} ${phase === "morning" ? "朝" : phase === "evening" ? "夜" : ""}の回答できる家事チェックはありません。個別の記録や昨日分の訂正を選べます。`, choices());
    return;
  }
  const id = String(session.session_id ?? session.id ?? "");
  if (!id || day !== inputDates().today) {
    await ctx.reply("入力対象が更新されています。入力を開き直してください。", [say("入力")]);
    return;
  }
  const actions: LineQuickReplyAction[] = [
    button("全部やった", "mc_reconcile", { session_id: id, response_kind: "all_done" }),
    button("大体やった", "mc_reconcile", { session_id: id, response_kind: "mostly_done" }),
    button("個別で答える", "mc_reconcile", { session_id: id, response_kind: "individual" }),
  ];
  for (const other of sessions.filter((row) => row !== session).slice(0, 3)) {
    actions.push(button(String(other.session_type) === "dropoff" ? "朝の作業へ" : "別の夜の作業へ", "mc_input_open", { day, session_id: String(other.session_id ?? other.id) }));
  }
  actions.push(...choices());
  await ctx.reply(`${day}\n${sessionLabel(session.session_type)}\n${typeof session.remaining_count === "number" ? `未記録 ${session.remaining_count}件\n` : ""}この範囲をどう記録しますか？\n「全部やった」は対象の必須・通常の項目だけを記録します。`, actions.slice(0, 13));
}

async function recentTasks(ctx: LineMustCompleteContext, day: string): Promise<Row[] | null> {
  const { data, error } = await ctx.client.from("task_instances")
    .select("id,title,status,revision,scheduled_date,due_at,planned_assignee_id,actual_completed_by_id,outcome_reason,assignment_mode,completion_mode,task_definitions(code)")
    .eq("household_id", ctx.householdId).eq("scheduled_date", day).is("test_context_id", null)
    .in("status", ["todo", "in_progress", "completed", "skipped"])
    .order("due_at", { ascending: true, nullsFirst: false }).order("id", { ascending: true });
  if (error) return null;
  return rows(data).filter((row) => row.planned_assignee_id === ctx.actorId || row.actual_completed_by_id === ctx.actorId
    || row.assignment_mode === "anyone" || row.planned_assignee_id == null
    || (row.task_definitions as Row | null)?.code === "codmon_submit");
}

function taskStatus(row: Row): string {
  return row.status === "completed" ? "完了済み" : row.status === "skipped" ? row.outcome_reason === "could_not_do" ? "できなかった" : "今回は不要など" : "未完了";
}
export async function handleDailyInputPostback(ctx: LineMustCompleteContext, fields: Record<string, string>): Promise<boolean> {
  if (!["mc_input_open", "mc_input_tasks", "mc_input_task", "mc_input_undo_failed", "mc_input_complete", "mc_input_children", "mc_input_uncheck"].includes(fields.action)) return false;
  const day = fields.day;
  if (!day || !validDay(day)) {
    await ctx.reply("この入力は日付が古くなっています。今日・昨日の入力を開き直してください。", choices());
    return true;
  }
  if (fields.action === "mc_input_open") {
    if (day !== inputDates().today) {
      await showRecent(ctx, day, 0);
    } else await openDailyInput(ctx, fields.phase, fields.session_id);
    return true;
  }
  if (fields.action === "mc_input_tasks") {
    await showRecent(ctx, day, /^\d{1,4}$/u.test(fields.page ?? "") ? Number(fields.page) : 0);
    return true;
  }
  if (fields.action === "mc_input_undo_failed") {
    if (!fields.task_id || !/^[1-9]\d*$/u.test(fields.revision ?? "")) return true;
    const op = await operationId(ctx, fields);
    const { error } = await ctx.client.rpc("server_tx_undo_line_daily_failure_v1", {
      p_actor_id: ctx.actorId, p_operation_id: op, p_task_id: fields.task_id,
      p_expected_revision: Number(fields.revision), p_day: day,
    });
    await ctx.reply(error ? "訂正結果を確認できませんでした。最新の記録を開いて確認してください。" : `${day}の「できなかった」を未完了に戻しました。`,
      [button("記録を確認", "mc_input_tasks", { day, page: "0" })]);
    return true;
  }
  if (fields.action === "mc_input_complete") {
    if (!fields.task_id || !/^[1-9]\d*$/u.test(fields.revision ?? "")) return true;
    const { data, error } = await ctx.client.rpc("server_tx_complete_line_daily_task_v1", {
      p_actor_id: ctx.actorId, p_operation_id: await operationId(ctx, fields), p_task_id: fields.task_id,
      p_expected_revision: Number(fields.revision), p_day: day, p_codmon_sent: fields.codmon_sent === "true",
    });
    const result = data as Row | null;
    const quick: LineQuickReplyAction[] = [];
    if (!error && Number.isSafeInteger(result?.revision) && Number(result?.revision) > 0) {
      quick.push(result?.completion_mode === "subtasks"
        ? button("項目を訂正", "mc_input_children", { task_id: fields.task_id, revision: String(result!.revision), day, page: "0" })
        : button("取り消す", "reopen_task", { task_id: fields.task_id, revision: String(result!.revision) }));
    }
    quick.push(button("記録を確認", "mc_input_tasks", { day, page: "0" }));
    await ctx.reply(error ? "記録結果を確認できませんでした。最新の記録から状態を確認してください。"
      : `${day}の「${String(result?.title ?? "選んだ作業")}」を完了として記録しました。`, quick);
    return true;
  }
  const tasks = await recentTasks(ctx, day);
  if (tasks === null) { await ctx.reply("作業を確認できませんでした。もう一度一覧を開いてください。", choices()); return true; }
  const task = tasks.find((row) => row.id === fields.task_id);
  if (!task || String(task.revision) !== fields.revision) {
    await ctx.reply("この作業は更新されています。最新の一覧から選び直してください。", [button("一覧を開く", "mc_input_tasks", { day, page: "0" })]);
    return true;
  }
  const taskId = String(task.id);
  if (fields.action === "mc_input_children" || fields.action === "mc_input_uncheck") {
    if (task.completion_mode !== "subtasks") {
      await ctx.reply("項目の構成が変わっています。記録を開き直してください。", choices()); return true;
    }
    const { data: childData, error } = await ctx.client.from("task_subtask_instances")
      .select("id,title,is_completed").eq("household_id", ctx.householdId).eq("task_instance_id", taskId)
      .is("test_context_id", null).eq("is_completed", true).order("sort_order").order("id");
    if (error) { await ctx.reply("チェック項目を読み込めませんでした。もう一度記録を開いてください。", choices()); return true; }
    const children = rows(childData);
    if (fields.action === "mc_input_uncheck") {
      if (!children.some((child) => child.id === fields.subtask_id)) {
        await ctx.reply("その項目は更新されています。最新の記録を開いてください。", choices()); return true;
      }
      const { error: writeError } = await ctx.client.rpc("server_tx_set_subtask_completion", {
        p_actor_id: ctx.actorId, p_operation_id: await operationId(ctx, { ...fields, task_id: `${taskId}:${fields.subtask_id}` }),
        p_subtask_instance_id: fields.subtask_id, p_completed: false, p_completion_actor: "self",
        p_expected_revision: Number(fields.revision),
      });
      await ctx.reply(writeError ? "訂正結果を確認できませんでした。最新の記録から確認してください。"
        : `${day}の「${String(task.title)}」の選んだ項目を未完了に戻しました。ほかの実施済み項目は残しています。`,
        [button("記録を確認", "mc_input_tasks", { day, page: "0" })]);
      return true;
    }
    const page = /^\d{1,4}$/u.test(fields.page ?? "") ? Number(fields.page) : 0;
    const offset = Math.min(page, Math.max(0, Math.ceil(children.length / PAGE_SIZE) - 1)) * PAGE_SIZE;
    const actions = children.slice(offset, offset + PAGE_SIZE).map((child, i) => button(`${i + offset + 1}を未完了へ`, "mc_input_uncheck", {
      task_id: taskId, revision: String(task.revision), subtask_id: String(child.id), day,
    }));
    if (offset > 0) actions.push(button("前の項目", "mc_input_children", { task_id: taskId, revision: String(task.revision), day, page: String(offset / PAGE_SIZE - 1) }));
    if (offset + PAGE_SIZE < children.length) actions.push(button("次の項目", "mc_input_children", { task_id: taskId, revision: String(task.revision), day, page: String(offset / PAGE_SIZE + 1) }));
    actions.push(button("記録に戻る", "mc_input_tasks", { day, page: "0" }));
    await ctx.reply(`${day} 「${String(task.title)}」\n未完了に戻す項目を選んでください。\n${children.slice(offset, offset + PAGE_SIZE).map((child, i) => `${offset + i + 1}. ${String(child.title)}`).join("\n") || "完了済みの項目はありません。"}`, actions);
    return true;
  }
  const actions: LineQuickReplyAction[] = [];
  if (task.completion_mode === "subtasks") actions.push(button("項目を確認・訂正", "mc_input_children", { task_id: taskId, revision: String(task.revision), day, page: "0" }));
  if (task.status === "completed" && task.completion_mode !== "subtasks") actions.push(button("未完了に戻す", "reopen_task", { task_id: taskId, revision: String(task.revision) }));
  else if (task.status === "skipped" && task.outcome_reason === "could_not_do") {
    // The canonical six-argument undo preserves a later partner revision.
    actions.push(button("できなかったを訂正", "mc_input_undo_failed", { task_id: taskId, revision: String(task.revision), day }));
  } else if (task.status === "todo" || task.status === "in_progress") {
    const definition = task.task_definitions as Row | null;
    const codmon = definition?.code === "codmon_submit";
    actions.push(button(codmon ? "コドモンを送信した" : "自分がやった", "mc_input_complete", {
      task_id: taskId, revision: String(task.revision), day, codmon_sent: String(codmon),
    }));
  }
  actions.push(button("一覧に戻る", "mc_input_tasks", { day, page: "0" }));
  await ctx.reply(`${day}の記録\n${String(task.title)}\n${taskStatus(task)}\n予定の担当と、実際に行った人は別に記録します。`, actions);
  return true;
}
async function showRecent(ctx: LineMustCompleteContext, day: string, page: number): Promise<void> {
  const tasks = await recentTasks(ctx, day);
  if (tasks === null) { await ctx.reply("記録を読み込めませんでした。もう一度開いてください。", choices()); return; }
  const offset = Math.min(page, Math.max(0, Math.ceil(tasks.length / PAGE_SIZE) - 1)) * PAGE_SIZE;
  const shown = tasks.slice(offset, offset + PAGE_SIZE);
  const actions = shown.map((row, i) => button(`${offset + i + 1}を確認・訂正`, "mc_input_task", { day, task_id: String(row.id), revision: String(row.revision) }));
  if (offset > 0) actions.push(button("前の記録", "mc_input_tasks", { day, page: String(offset / PAGE_SIZE - 1) }));
  if (offset + PAGE_SIZE < tasks.length) actions.push(button("次の記録", "mc_input_tasks", { day, page: String(offset / PAGE_SIZE + 1) }));
  actions.push(...choices());
  await ctx.reply(`${day}の記録（${tasks.length}件）\n${shown.length ? shown.map((row, i) => `${offset + i + 1}. ${String(row.title)}（${taskStatus(row)}）`).join("\n") : "対象の作業はありません。"}\n確認・訂正する作業を選んでください。`, actions.slice(0, 13));
}

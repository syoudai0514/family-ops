// One-line completion reports over LINE ("送りました!", "洗濯した", "やった").
//
// Before this module a completion report was always decomposed into an
// `actual_record` draft whose only content was a title plus a hard-coded
// missing field "実績にする作業" -- nothing ever matched the report to a task
// that was actually scheduled. Live 2026-09-25 and 2026-09-30 ("送りました!"
// -> a draft "送付完了" with a single "取り消す" button): the Codmon task stayed
// open, and the user had no way to answer the bot's question. Completions
// were almost never recorded in production, which is what made every brief
// list finished work.
//
// This file is deliberately split in two: pure parsing / ranking (unit tested)
// and a small handler that reads the sender's open tasks for today and
// completes the match through the same canonical RPC the PWA uses.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";

export type OpenTask = {
  id: string;
  title: string;
  code: string | null;
  due_at: string | null;
  revision: number;
};

export type CompletionReport =
  | { kind: "send" }
  | { kind: "generic" }
  | { kind: "hint"; hint: string };

// Longest alternatives first so "送りました" is never read as "送り" + "ました".
const SEND_VERBS = "送りました|送った|送信しました|送信した";
const OTHER_VERBS =
  "終わりました|終わった|済ませました|済ませた|済みました|済んだ|できました|できた|やりました|やった|出しました|出した|完了しました|完了です|完了|終了|しました|した";
const TAIL = "[\\s!。.よですね〜~]*";
const SEND_RE = new RegExp(`^(?:${SEND_VERBS})${TAIL}$`, "u");
const BARE_RE = new RegExp(`^(?:${OTHER_VERBS})${TAIL}$`, "u");
const HINTED_RE = new RegExp(`^(.{1,20}?)(?:を|は|も|、)?(?:${SEND_VERBS}|${OTHER_VERBS})${TAIL}$`, "u");
const HINT_NOISE = /^(?:もう|さっき|今|今日は?|ちゃんと|無事)+/u;

function norm(value: string): string {
  return value.normalize("NFKC").replace(/\s+/gu, "").toLowerCase();
}

/** Strict on purpose: only a short, bare "I did it" sentence qualifies. */
export function parseCompletionReport(text: string): CompletionReport | null {
  const t = text.normalize("NFKC").trim();
  if (t.length === 0 || t.length > 30) return null;
  if (/[?？]/u.test(t)) return null;
  if (SEND_RE.test(t)) return { kind: "send" };
  if (BARE_RE.test(t)) return { kind: "generic" };
  const hinted = t.match(HINTED_RE);
  if (!hinted) return null;
  const hint = norm(hinted[1].replace(HINT_NOISE, ""));
  if (hint.length === 0) return { kind: "generic" };
  if (hint.length < 2) return null;
  return { kind: "hint", hint };
}

/** Tasks that plausibly are what the sender just finished, best first. */
export function rankCompletionCandidates(
  tasks: OpenTask[],
  report: CompletionReport,
  nowMs: number,
): OpenTask[] {
  if (report.kind === "send") {
    const codmon = tasks.filter((t) => t.code === "codmon_submit");
    const dropoff = tasks.filter((t) => t.code === "dropoff");
    return [...codmon, ...dropoff];
  }
  if (report.kind === "hint") {
    const submit = tasks.filter((t) => t.code === "codmon_submit");
    if (report.hint.includes("コドモン") && !/入力|記入/u.test(report.hint) && submit.length > 0) {
      return submit;
    }
    return tasks.filter((t) => norm(t.title).includes(report.hint));
  }
  // Bare "やった": most recently due first, then the soonest upcoming.
  const due = (t: OpenTask) => (t.due_at ? Date.parse(t.due_at) : Number.NaN);
  const past = tasks.filter((t) => due(t) <= nowMs).sort((a, b) => due(b) - due(a));
  const upcoming = tasks.filter((t) => !(due(t) <= nowMs)).sort((a, b) => (due(a) || Infinity) - (due(b) || Infinity));
  return [...past, ...upcoming];
}

function clip(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max - 1)}…`;
}

function quickPostback(label: string, data: string, displayText = label): LineQuickReplyAction {
  return { type: "postback", label: clip(label, 20), data, displayText: clip(displayText, 40) };
}

function todayUrl(): string {
  const base = (Deno.env.get("APP_BASE_URL") ?? "").replace(/\/$/, "");
  return base ? `${base}/today` : "";
}

const TODAY_QUICK_REPLY: LineQuickReplyAction = { type: "message", label: "今日を見る", text: "今日" };

export type CompletionContext = {
  client: SupabaseClient;
  actorId: string;
  householdId: string;
  eventId: string;
  today: string; // JST yyyy-mm-dd
  operationId: (...parts: string[]) => Promise<string>;
  reply: (text: string, quickReplies?: LineQuickReplyAction[]) => Promise<void>;
};

async function loadOpenTasks(ctx: CompletionContext): Promise<OpenTask[]> {
  const { data: rows } = await ctx.client.from("task_instances")
    .select("id,title,due_at,revision,task_definition_id")
    .eq("household_id", ctx.householdId)
    .eq("scheduled_date", ctx.today)
    .is("test_context_id", null)
    .in("status", ["todo", "in_progress"])
    .or(`planned_assignee_id.eq.${ctx.actorId},planned_assignee_id.is.null`)
    .limit(60);
  const tasks = (rows ?? []) as Array<{
    id: string; title: string; due_at: string | null; revision: number; task_definition_id: string | null;
  }>;
  const defIds = [...new Set(tasks.map((t) => t.task_definition_id).filter((v): v is string => Boolean(v)))];
  const codeById = new Map<string, string>();
  if (defIds.length > 0) {
    const { data: defs } = await ctx.client.from("task_definitions").select("id,code").in("id", defIds);
    for (const d of (defs ?? []) as Array<{ id: string; code: string }>) codeById.set(d.id, d.code);
  }
  return tasks.map((t) => ({
    id: t.id,
    title: t.title,
    code: t.task_definition_id ? codeById.get(t.task_definition_id) ?? null : null,
    due_at: t.due_at,
    revision: t.revision,
  }));
}

/**
 * Completes one task for the sender and answers in plain words. Shared by the
 * one-line report path and by the `complete_task` postback so both give the
 * same feedback -- the postback used to swallow failures silently.
 */
export async function completeTaskAndReply(
  ctx: CompletionContext,
  taskId: string,
  title: string | null,
  operationId: string,
  completionActor: "self" | "partner" = "self",
  completeRemainingSubtasks = true,
): Promise<void> {
  const { error } = await ctx.client.rpc("server_tx_complete_task", {
    p_actor_id: ctx.actorId,
    p_operation_id: operationId,
    p_task_id: taskId,
    p_completion_actor: completionActor,
    p_complete_remaining_subtasks: completeRemainingSubtasks,
    p_source: "line",
  });
  const link = todayUrl();
  const name = title ? `「${clip(title, 40)}」` : "この作業";
  if (error) {
    const message = error.message ?? "";
    console.warn("process-line-inbox: LINE completion failed", { message: message.slice(0, 120) });
    if (message.includes("CODMON_INPUTS_INCOMPLETE")) {
      await ctx.reply(
        `${name}はまだ完了にできません。コドモンの入力がそろっていません。${link ? `\n残りの入力はここで確認できます\n${link}` : ""}`,
        [TODAY_QUICK_REPLY],
      );
    } else if (message.includes("TASK_TERMINAL")) {
      await ctx.reply(`${name}はすでに完了（またはスキップ）になっています。`, [TODAY_QUICK_REPLY]);
    } else {
      await ctx.reply(`${name}を完了にできませんでした。${link ? `\nTodayから操作してください\n${link}` : ""}`, [TODAY_QUICK_REPLY]);
    }
    return;
  }
  const { data: after } = await ctx.client.from("task_instances").select("revision").eq("id", taskId).maybeSingle();
  const revision = (after as { revision?: number } | null)?.revision;
  const quick: LineQuickReplyAction[] = [];
  if (typeof revision === "number") {
    quick.push(quickPostback("取り消す", `action=reopen_task&task_id=${taskId}&revision=${revision}`));
  }
  quick.push(TODAY_QUICK_REPLY);
  await ctx.reply(`✓ ${name}を完了にしました。`, quick);
}

export async function reopenTaskAndReply(ctx: CompletionContext, taskId: string, revision: number, operationId: string): Promise<void> {
  const { error } = await ctx.client.rpc("server_tx_reopen_task", {
    p_actor_id: ctx.actorId,
    p_operation_id: operationId,
    p_task_id: taskId,
    p_expected_revision: revision,
    p_source: "line",
  });
  if (error) {
    console.warn("process-line-inbox: LINE reopen failed", { message: (error.message ?? "").slice(0, 120) });
    await ctx.reply("元に戻せませんでした。すでに状態が変わっている可能性があります。Todayで確認してください。", [TODAY_QUICK_REPLY]);
    return;
  }
  await ctx.reply("元に戻しました（未完了）。", [TODAY_QUICK_REPLY]);
}

function chooseReply(candidates: OpenTask[]): { text: string; quick: LineQuickReplyAction[] } {
  const shown = candidates.slice(0, 4);
  return {
    text: "どの作業を完了にしますか？",
    quick: [
      ...shown.map((t) => quickPostback(t.title, `action=complete_task&task_id=${t.id}&completion_actor=self&complete_remaining=true`, `完了: ${t.title}`)),
      TODAY_QUICK_REPLY,
    ],
  };
}

/** Returns true when the message was handled here (so it is not decomposed into drafts). */
export async function tryHandleCompletionReport(ctx: CompletionContext, text: string): Promise<boolean> {
  const report = parseCompletionReport(text);
  if (!report) return false;

  const tasks = await loadOpenTasks(ctx);
  const ranked = rankCompletionCandidates(tasks, report, Date.now());

  if (report.kind === "hint" && ranked.length === 0) return false; // not one of today's tasks: let the normal flow decide

  if (ranked.length === 0) {
    const link = todayUrl();
    await ctx.reply(`今日の未完了の作業は見つかりませんでした。${link ? `\n${link}` : ""}`, [TODAY_QUICK_REPLY]);
    return true;
  }

  // Bare "やった" says nothing about which task, so never guess: ask.
  if (ranked.length === 1 && report.kind !== "generic") {
    const task = ranked[0];
    await completeTaskAndReply(ctx, task.id, task.title, await ctx.operationId("line-complete-report", ctx.eventId, task.id));
    return true;
  }

  const { text: prompt, quick } = chooseReply(ranked);
  await ctx.reply(prompt, quick);
  return true;
}

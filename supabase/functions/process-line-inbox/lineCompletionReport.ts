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

// --- Codmon "sent" reports -------------------------------------------------

export const CODMON_INPUT_LABELS: Record<string, string> = {
  codmon_masaki_pickup_input: "将生：迎え",
  codmon_shino_previous_input: "詩乃：昨日の夕飯・様子",
  codmon_shino_breakfast_input: "詩乃：朝食",
  codmon_shino_pickup_input: "詩乃：迎え",
};
const ALL_CODMON_INPUTS = Object.keys(CODMON_INPUT_LABELS);

export type CodmonSentReport = {
  /** Inputs the sender says the other adult had already done. */
  partnerCodes: string[];
  /** Extra remarks we could not map to an input; reported back, never guessed. */
  unreadNotes: string[];
};

const SENT_VERB = /(送りました|送った|送信しました|送信した|送信済み|送信完了)/u;
const RECENT_PREFIX = "(?:今日(?:は|も|の)?|今朝(?:は|も)?|さっき|先ほど|今|もう|無事|ちゃんと)\\s*";
// A verb appearing inside a desire, question or denial is not a report. This
// fallback has no conversational date resolution, so only today's explicit
// affirmative send can close today's submit and its still-open inputs.
const AFFIRMATIVE_SENT_CLAUSE = new RegExp(
  `^(?:${RECENT_PREFIX})*(?:コドモン(?:の(?:連絡帳|連絡|入力))?(?:を|は|も)?\\s*)?(?:${RECENT_PREFIX})*${SENT_VERB.source}(?:よ|です|だよ|んだよ)?[\\s〜~]*$`,
  "u",
);
const OTHER_DAY_CONTEXT = /^(?:昨日|きのう|一昨日|おととい|明日|あした|明後日|あさって|先週|先月|去年|\d+日前)(?:は|に|の分)?$/u;
const SEND_RETRACTION = /^(?:でも\s*)?(?:送れて(?:い)?ない|送信(?:して(?:い)?ない|失敗)|失敗(?:した|しました)|取り消した|取消した)/u;
const ALREADY_DONE = /(やって(あった|ある|あります|くれてた|くれていた|くれた|もらった)|入力(して)?(あった|ある|あります|済み|してくれてた|してくれた)|(は|も)済み|済んで(た|いた))/u;

function codmonCodesIn(clause: string): string[] {
  if (/(全部|全て|すべて|ぜんぶ)/u.test(clause)) return [...ALL_CODMON_INPUTS];
  const masaki = /将生/u.test(clause);
  const shino = /詩乃/u.test(clause);
  const codes = new Set<string>();
  if (/朝(食|ごはん|ご飯)/u.test(clause)) codes.add("codmon_shino_breakfast_input");
  if (/(夕飯|夕食|晩(ごはん|ご飯)|様子|昨日)/u.test(clause)) codes.add("codmon_shino_previous_input");
  if (/(迎え|プール)/u.test(clause)) {
    if (masaki || !shino) codes.add("codmon_masaki_pickup_input");
    if (shino || !masaki) codes.add("codmon_shino_pickup_input");
  }
  if (codes.size === 0 && masaki && !shino) codes.add("codmon_masaki_pickup_input");
  return [...codes];
}

/**
 * "コドモン送りました" (optionally with "朝食はやってあった" etc.). Owner decision
 * 2026-09-30: whoever reports the send did every unticked input, except the
 * ones they say were already done -- those were the other adult's.
 */
export function parseCodmonSentReport(text: string): CodmonSentReport | null {
  const t = text.normalize("NFKC").trim();
  if (t.length === 0 || t.length > 120 || /[?？]/u.test(t) || !/コドモン/u.test(t)) return null;
  const clauses = t.split(/[。、,\n!！]+|(?:ので|から|けど|けれど)/u).map((c) => c.trim()).filter(Boolean);
  if (clauses.some((c) => OTHER_DAY_CONTEXT.test(c) || SEND_RETRACTION.test(c))) return null;
  const sentClauses = new Set(clauses.filter((c) => AFFIRMATIVE_SENT_CLAUSE.test(c)));
  if (sentClauses.size === 0) return null;
  const partner = new Set<string>();
  const unreadNotes: string[] = [];
  for (const clause of clauses) {
    if (sentClauses.has(clause)) continue;
    const codes = ALREADY_DONE.test(clause) ? codmonCodesIn(clause) : [];
    if (codes.length === 0) {
      unreadNotes.push(clause);
      continue;
    }
    for (const code of codes) partner.add(code);
  }
  return { partnerCodes: ALL_CODMON_INPUTS.filter((code) => partner.has(code)), unreadNotes };
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

// `for` names who the link was sent to, so the PWA can say so when the browser
// LINE opens is signed in as someone else (live 2026-09-30: papa's LINE opened
// a browser still signed in as mama, and Today showed only mama's work).
// A member id, not a credential.
function todayUrl(forUserId: string): string {
  const base = (Deno.env.get("APP_BASE_URL") ?? "").replace(/\/$/, "");
  return base ? `${base}/today?for=${encodeURIComponent(forUserId)}` : "";
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

export async function loadOpenTasks(ctx: CompletionContext): Promise<OpenTask[]> {
  const { data: rows } = await ctx.client.from("task_instances")
    .select("id,title,due_at,revision,task_definition_id,planned_assignee_id")
    .eq("household_id", ctx.householdId)
    .eq("scheduled_date", ctx.today)
    .is("test_context_id", null)
    .in("status", ["todo", "in_progress"])
    .limit(80);
  const tasks = (rows ?? []) as Array<{
    id: string; title: string; due_at: string | null; revision: number;
    task_definition_id: string | null; planned_assignee_id: string | null;
  }>;
  const defIds = [...new Set(tasks.map((t) => t.task_definition_id).filter((v): v is string => Boolean(v)))];
  const codeById = new Map<string, string>();
  if (defIds.length > 0) {
    const { data: defs } = await ctx.client.from("task_definitions").select("id,code").in("id", defIds);
    for (const d of (defs ?? []) as Array<{ id: string; code: string }>) codeById.set(d.id, d.code);
  }
  return tasks
    .map((t) => ({
      id: t.id,
      title: t.title,
      code: t.task_definition_id ? codeById.get(t.task_definition_id) ?? null : null,
      due_at: t.due_at,
      revision: t.revision,
      assignee: t.planned_assignee_id,
    }))
    // Your own and unassigned work. Codmon submission is whoever sent it:
    // whichever parent pressed send in Codmon can report it.
    .filter((t) => t.assignee === ctx.actorId || t.assignee === null || t.code === "codmon_submit")
    .map(({ assignee: _assignee, ...task }) => task);
}

async function taskCode(ctx: CompletionContext, taskId: string): Promise<string | null> {
  const { data: task } = await ctx.client.from("task_instances").select("task_definition_id").eq("id", taskId).maybeSingle();
  const definitionId = (task as { task_definition_id?: string | null } | null)?.task_definition_id;
  if (!definitionId) return null;
  const { data: definition } = await ctx.client.from("task_definitions").select("code").eq("id", definitionId).maybeSingle();
  return (definition as { code?: string | null } | null)?.code ?? null;
}

/**
 * The Codmon inputs still open on the submit's day that the OTHER adult is assigned to.
 * Live 2026-10-02 11:22: "コドモンも終わっているよ" closed ママ's open input as the
 * sender's own work. Once Codmon is sent, the assigned adult did their input.
 * Best effort: a failed read just means nothing is credited to the partner.
 */
async function partnerAssignedOpenInputCodes(ctx: CompletionContext, submitTaskId: string): Promise<string[]> {
  try {
    const { data: submit } = await ctx.client.from("task_instances").select("scheduled_date").eq("id", submitTaskId).maybeSingle();
    const date = (submit as { scheduled_date?: string } | null)?.scheduled_date ?? ctx.today;
    const { data: defs } = await ctx.client
      .from("task_definitions")
      .select("id,code")
      .eq("household_id", ctx.householdId)
      .in("code", ALL_CODMON_INPUTS);
    const codeById = new Map(
      ((defs ?? []) as Array<{ id: string; code: string }>)
        .filter((d) => ALL_CODMON_INPUTS.includes(d.code))
        .map((d) => [d.id, d.code]),
    );
    if (!codeById.size) return [];
    const { data: rows } = await ctx.client
      .from("task_instances")
      .select("task_definition_id,planned_assignee_id,status,scheduled_date")
      .eq("household_id", ctx.householdId)
      .eq("scheduled_date", date)
      .in("task_definition_id", [...codeById.keys()])
      .in("status", ["todo", "in_progress"])
      .is("test_context_id", null);
    return [...new Set(
      ((rows ?? []) as Array<{ task_definition_id: string; planned_assignee_id: string | null; status: string }>)
        .filter((r) => codeById.has(r.task_definition_id) && (r.status === "todo" || r.status === "in_progress"))
        .filter((r) => r.planned_assignee_id && r.planned_assignee_id !== ctx.actorId)
        .map((r) => codeById.get(r.task_definition_id)!),
    )];
  } catch {
    return [];
  }
}

/**
 * Completes one task for the sender and answers in plain words. Shared by the
 * one-line report path and by the `complete_task` postback so both give the
 * same feedback -- the postback used to swallow failures silently.
 *
 * Codmon submission (owner decision 2026-09-30): reporting that Codmon was
 * sent ends the job. Inputs nobody ticked in the app are closed in the same
 * transaction (server_tx_acknowledge_codmon_submission_v1) instead of refusing
 * with "コドモンの入力がそろっていません".
 */
export async function completeTaskAndReply(
  ctx: CompletionContext,
  taskId: string,
  options: {
    operationId: string;
    title?: string | null;
    code?: string | null;
    completionActor?: "self" | "partner";
    completeRemainingSubtasks?: boolean;
    /** Codmon only: inputs the sender said the other adult had already done. */
    partnerInputCodes?: string[];
    unreadNotes?: string[];
  },
): Promise<void> {
  const code = options.code !== undefined ? options.code : await taskCode(ctx, taskId);
  const codmon = code === "codmon_submit";
  const partnerInputCodes = codmon
    ? [...new Set([...(options.partnerInputCodes ?? []), ...await partnerAssignedOpenInputCodes(ctx, taskId)])]
    : [];
  const { data, error } = codmon
    ? await ctx.client.rpc("server_tx_acknowledge_codmon_submission_v1", {
      p_actor_id: ctx.actorId,
      p_operation_id: options.operationId,
      p_submit_task_id: taskId,
      p_source: "line",
      p_partner_input_codes: partnerInputCodes.length ? partnerInputCodes : null,
    })
    : await ctx.client.rpc("server_tx_complete_task", {
      p_actor_id: ctx.actorId,
      p_operation_id: options.operationId,
      p_task_id: taskId,
      p_completion_actor: options.completionActor ?? "self",
      p_complete_remaining_subtasks: options.completeRemainingSubtasks ?? true,
      p_source: "line",
    });
  const link = todayUrl(ctx.actorId);
  const name = codmon ? "コドモン送信" : options.title ? `「${clip(options.title, 40)}」` : "この作業";
  if (error) {
    const message = error.message ?? "";
    console.warn("process-line-inbox: LINE completion failed", { message: message.slice(0, 120) });
    if (message.includes("CODMON_INPUTS_INCOMPLETE")) {
      // Only reachable when the day's Codmon rows are missing or duplicated.
      await ctx.reply(
        `コドモン送信を記録できませんでした。今日の入力の項目が正しく作られていません。${link ? `\nTodayで確認してください\n${link}` : ""}`,
        [TODAY_QUICK_REPLY],
      );
    } else if (message.includes("TASK_TERMINAL")) {
      await ctx.reply(`${name}はすでに完了になっています。`, [TODAY_QUICK_REPLY]);
    } else {
      await ctx.reply(`${name}を完了にできませんでした。${link ? `\nTodayから操作してください\n${link}` : ""}`, [TODAY_QUICK_REPLY]);
    }
    return;
  }
  // An intervening reopen/recompletion must not give this old confirmation
  // permission to undo the later work. Replays keep the receipt's revision.
  const revision = (data as { revision?: number } | null)?.revision;
  const quick: LineQuickReplyAction[] = [];
  if (typeof revision === "number" && Number.isSafeInteger(revision) && revision > 0) {
    quick.push(quickPostback("取り消す", `action=reopen_task&task_id=${taskId}&revision=${revision}`));
  }
  quick.push(TODAY_QUICK_REPLY);
  if (!codmon) {
    await ctx.reply(`✓ ${name}を完了にしました。`, quick);
    return;
  }
  const result = data as { inputs_closed?: number; inputs_closed_by_partner?: number } | null;
  const closed = Number(result?.inputs_closed ?? 0);
  const byPartner = Number(result?.inputs_closed_by_partner ?? 0);
  const lines = ["✓ コドモン送信を完了にしました。"];
  if (closed > 0) {
    const partnerLabels = partnerInputCodes.map((code) => CODMON_INPUT_LABELS[code]).filter(Boolean);
    if (byPartner > 0) {
      const who = partnerLabels.length > 0 ? `${partnerLabels.join("・")}は` : `うち${byPartner}件は`;
      const rest = closed - byPartner > 0 ? "相手、残りはあなたの実施として記録しています。" : "相手の実施として記録しています。";
      lines.push(`チェックされていなかった入力${closed}件も完了にしました。${who}${rest}`);
    } else {
      lines.push(`チェックされていなかった入力${closed}件も、あなたの実施として完了にしました。`);
    }
  }
  const notes = (options.unreadNotes ?? []).filter((note) => note.length > 0);
  if (notes.length > 0 && closed > 0) {
    lines.push(`「${clip(notes.join("、"), 40)}」はどの入力か分からなかったため、あなたの実施にしています。`);
  }
  await ctx.reply(lines.join("\n"), quick);
}

/**
 * "詩乃の薬あげるの忘れちゃった": recorded as できなかった, kept apart from an open
 * (未記録) todo. One tap undoes it (back to todo).
 */
export async function couldNotDoAndReply(
  ctx: CompletionContext,
  taskId: string,
  options: { operationId: string; title?: string | null },
): Promise<void> {
  const { error } = await ctx.client.rpc("server_tx_mark_task_could_not_do_v1", {
    p_actor_id: ctx.actorId,
    p_operation_id: options.operationId,
    p_task_id: taskId,
    p_undo: false,
    p_source: "line",
  });
  const name = options.title ? `「${clip(options.title, 40)}」` : "この作業";
  if (error) {
    const message = error.message ?? "";
    console.warn("process-line-inbox: LINE could-not-do failed", { message: message.slice(0, 120) });
    await ctx.reply(
      message.includes("TASK_TERMINAL")
        ? `${name}はすでに完了か取り消しになっています。`
        : `${name}を「できなかった」にできませんでした。Todayから操作してください。`,
      [TODAY_QUICK_REPLY],
    );
    return;
  }
  await ctx.reply(
    `− ${name}は今日は「できなかった」で記録しました（未記録とは別に残ります）。`,
    [quickPostback("取り消す", `action=could_not_do_undo&task_id=${taskId}`), TODAY_QUICK_REPLY],
  );
}

export async function undoCouldNotDoAndReply(ctx: CompletionContext, taskId: string, operationId: string): Promise<void> {
  const { error } = await ctx.client.rpc("server_tx_mark_task_could_not_do_v1", {
    p_actor_id: ctx.actorId,
    p_operation_id: operationId,
    p_task_id: taskId,
    p_undo: true,
    p_source: "line",
  });
  if (error) {
    console.warn("process-line-inbox: LINE could-not-do undo failed", { message: (error.message ?? "").slice(0, 120) });
    await ctx.reply("元に戻せませんでした。すでに状態が変わっている可能性があります。Todayで確認してください。", [TODAY_QUICK_REPLY]);
    return;
  }
  await ctx.reply("「できなかった」を取り消しました（未完了に戻しました）。", [TODAY_QUICK_REPLY]);
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
  const codmonReport = parseCodmonSentReport(text);
  if (codmonReport) {
    const submit = (await loadOpenTasks(ctx)).find((task) => task.code === "codmon_submit");
    if (!submit) {
      const link = todayUrl(ctx.actorId);
      await ctx.reply(`今日の未完了のコドモン送信は見つかりませんでした（すでに完了している可能性があります）。${link ? `\n${link}` : ""}`, [TODAY_QUICK_REPLY]);
      return true;
    }
    await completeTaskAndReply(ctx, submit.id, {
      title: submit.title,
      code: submit.code,
      operationId: await ctx.operationId("line-complete-report", ctx.eventId, submit.id),
      partnerInputCodes: codmonReport.partnerCodes,
      unreadNotes: codmonReport.unreadNotes,
    });
    return true;
  }

  // A rejected Codmon send must not become a generic title hint: e.g.
  // "昨日コドモン送った" would otherwise match today's codmon_submit again.
  if (/コドモン/u.test(text) && SENT_VERB.test(text)) return false;

  const report = parseCompletionReport(text);
  if (!report) return false;

  const tasks = await loadOpenTasks(ctx);
  const ranked = rankCompletionCandidates(tasks, report, Date.now());

  if (report.kind === "hint" && ranked.length === 0) return false; // not one of today's tasks: let the normal flow decide

  if (ranked.length === 0) {
    const link = todayUrl(ctx.actorId);
    await ctx.reply(`今日の未完了の作業は見つかりませんでした。${link ? `\n${link}` : ""}`, [TODAY_QUICK_REPLY]);
    return true;
  }

  // Bare "やった" says nothing about which task, so never guess: ask.
  if (ranked.length === 1 && report.kind !== "generic") {
    const task = ranked[0];
    await completeTaskAndReply(ctx, task.id, {
      title: task.title,
      code: task.code,
      operationId: await ctx.operationId("line-complete-report", ctx.eventId, task.id),
    });
    return true;
  }

  const { text: prompt, quick } = chooseReply(ranked);
  await ctx.reply(prompt, quick);
  return true;
}

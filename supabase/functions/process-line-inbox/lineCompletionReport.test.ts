import { assertEquals } from "jsr:@std/assert@1";
import {
  completeTaskAndReply,
  type CompletionContext,
  type OpenTask,
  parseCompletionReport,
  rankCompletionCandidates,
  tryHandleCompletionReport,
} from "./lineCompletionReport.ts";

const NOW = Date.parse("2026-09-30T04:31:00+09:00");
const task = (id: string, title: string, code: string | null, due: string | null = null): OpenTask => ({
  id, title, code, due_at: due, revision: 3,
});

Deno.test("parse: the exact live message and its variants are completion reports", () => {
  assertEquals(parseCompletionReport("送りました！"), { kind: "send" });
  assertEquals(parseCompletionReport("送りました"), { kind: "send" });
  assertEquals(parseCompletionReport("送信した"), { kind: "send" });
  assertEquals(parseCompletionReport("やった"), { kind: "generic" });
  assertEquals(parseCompletionReport("終わったよ!"), { kind: "generic" });
  assertEquals(parseCompletionReport("洗濯した"), { kind: "hint", hint: "洗濯" });
  assertEquals(parseCompletionReport("もう洗濯しました。"), { kind: "hint", hint: "洗濯" });
  assertEquals(parseCompletionReport("ゴミ出しをやった"), { kind: "hint", hint: "ゴミ出し" });
});

Deno.test("parse: questions, requests and long or compound text are not touched", () => {
  for (const text of [
    "送りました?",
    "洗濯した？",
    "明日の夜にゴミ出しをする",
    "買い物きている。なに変えば良い?",
    "月曜に朝プールの用意が必要なので、お願いしますね。",
    "今日19時から花火大会だから、17時に詩乃を迎えにいく。それと洗濯した",
    "牛乳買った",
    "",
  ]) assertEquals(parseCompletionReport(text), null, text);
});

Deno.test("rank: 送りました is Codmon first, dropoff second -- never a guess between them", () => {
  const tasks = [
    task("d", "送り", "dropoff"),
    task("c", "コドモン送信", "codmon_submit"),
    task("x", "夕食対応", "dinner"),
  ];
  assertEquals(rankCompletionCandidates(tasks, { kind: "send" }, NOW).map((t) => t.id), ["c", "d"]);
  assertEquals(rankCompletionCandidates([tasks[0]], { kind: "send" }, NOW).map((t) => t.id), ["d"]);
  assertEquals(rankCompletionCandidates([tasks[2]], { kind: "send" }, NOW), []);
});

Deno.test("rank: a hint matches by title; コドモン resolves to the submit task, not each input", () => {
  const tasks = [
    task("w", "洗濯を回す", "laundry"),
    task("i", "詩乃：コドモン入力（朝食）", "codmon_input"),
    task("c", "コドモン送信", "codmon_submit"),
  ];
  assertEquals(rankCompletionCandidates(tasks, { kind: "hint", hint: "洗濯" }, NOW).map((t) => t.id), ["w"]);
  assertEquals(rankCompletionCandidates(tasks, { kind: "hint", hint: "コドモン" }, NOW).map((t) => t.id), ["c"]);
  assertEquals(rankCompletionCandidates(tasks, { kind: "hint", hint: "コドモン入力" }, NOW).map((t) => t.id), ["i"]);
  assertEquals(rankCompletionCandidates(tasks, { kind: "hint", hint: "皿洗い" }, NOW), []);
});

Deno.test("rank: a bare やった lists the most recently due task first", () => {
  const tasks = [
    task("late", "夕食", null, "2026-09-30T18:00:00+09:00"),
    task("a", "朝食", null, "2026-09-30T07:00:00+09:00"),
    task("b", "送り", null, "2026-09-30T08:00:00+09:00"),
  ];
  const at = Date.parse("2026-09-30T09:00:00+09:00");
  assertEquals(rankCompletionCandidates(tasks, { kind: "generic" }, at).map((t) => t.id), ["b", "a", "late"]);
});

// --- handler -------------------------------------------------------------

type Call = { fn: string; args: Record<string, unknown> };

function fakeContext(opts: { tasks: unknown[]; defs: unknown[]; rpcError?: string }) {
  const calls: Call[] = [];
  const replies: Array<{ text: string; quick?: unknown[] }> = [];
  const builder = (table: string) => {
    const chain: Record<string, unknown> = {};
    const self = () => chain;
    for (const m of ["eq", "is", "in", "or", "limit"]) chain[m] = self;
    chain.select = self;
    chain.maybeSingle = () => Promise.resolve({ data: { revision: 4 }, error: null });
    chain.then = (resolve: (v: unknown) => void) =>
      resolve({ data: table === "task_instances" ? opts.tasks : opts.defs, error: null });
    return chain;
  };
  const client = {
    from: (table: string) => builder(table),
    rpc: (fn: string, args: Record<string, unknown>) => {
      calls.push({ fn, args });
      return Promise.resolve({ error: opts.rpcError ? { message: opts.rpcError } : null });
    },
  };
  const ctx = {
    client,
    actorId: "u1",
    householdId: "h1",
    eventId: "evt",
    today: "2026-09-30",
    operationId: (...parts: string[]) => Promise.resolve(parts.join("|")),
    reply: (text: string, quick?: unknown[]) => {
      replies.push({ text, quick });
      return Promise.resolve();
    },
  } as unknown as CompletionContext;
  return { ctx, calls, replies };
}

const rows = [
  { id: "t-c", title: "コドモン送信", due_at: null, revision: 3, task_definition_id: "d-c" },
  { id: "t-d", title: "送り", due_at: null, revision: 3, task_definition_id: "d-d" },
];
const defs = [{ id: "d-c", code: "codmon_submit" }, { id: "d-d", code: "dropoff" }];

Deno.test("handler: 送りました with Codmon and dropoff open asks which one and completes nothing", async () => {
  const { ctx, calls, replies } = fakeContext({ tasks: rows, defs });
  assertEquals(await tryHandleCompletionReport(ctx, "送りました！"), true);
  assertEquals(calls.length, 0);
  assertEquals(replies[0].text, "どの作業を完了にしますか？");
  const labels = (replies[0].quick as Array<{ label: string }>).map((q) => q.label);
  assertEquals(labels, ["コドモン送信", "送り", "今日を見る"]);
});

Deno.test("handler: a single match completes through the canonical RPC and offers 取り消す", async () => {
  const { ctx, calls, replies } = fakeContext({ tasks: [rows[1]], defs });
  assertEquals(await tryHandleCompletionReport(ctx, "送りました！"), true);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].fn, "server_tx_complete_task");
  assertEquals(calls[0].args.p_task_id, "t-d");
  assertEquals(calls[0].args.p_source, "line");
  assertEquals(calls[0].args.p_completion_actor, "self");
  assertEquals(replies[0].text, "✓ 「送り」を完了にしました。");
  const undo = (replies[0].quick as Array<{ data?: string }>)[0];
  assertEquals(undo.data, "action=reopen_task&task_id=t-d&revision=4");
});

Deno.test("handler: unrelated text and unmatched hints fall through to the normal flow", async () => {
  const { ctx, calls, replies } = fakeContext({ tasks: rows, defs });
  assertEquals(await tryHandleCompletionReport(ctx, "牛乳買った"), false);
  assertEquals(await tryHandleCompletionReport(ctx, "皿洗いした"), false);
  assertEquals(calls.length + replies.length, 0);
});

Deno.test("handler: incomplete Codmon inputs are explained, not silently dropped", async () => {
  const { ctx, replies } = fakeContext({ tasks: [rows[0]], defs, rpcError: "CODMON_INPUTS_INCOMPLETE" });
  assertEquals(await tryHandleCompletionReport(ctx, "送りました！"), true);
  assertEquals(replies[0].text.includes("コドモンの入力がそろっていません"), true);
});

Deno.test("complete: an already-finished task says so", async () => {
  const { ctx, replies } = fakeContext({ tasks: [], defs: [], rpcError: "TASK_TERMINAL" });
  await completeTaskAndReply(ctx, "t-x", "夕食", "op");
  assertEquals(replies[0].text, "「夕食」はすでに完了（またはスキップ）になっています。");
});

Deno.test("handler: nothing open and a bare やった says so instead of inventing a task", async () => {
  const { ctx, replies } = fakeContext({ tasks: [], defs: [] });
  assertEquals(await tryHandleCompletionReport(ctx, "やった"), true);
  assertEquals(replies[0].text.startsWith("今日の未完了の作業は見つかりませんでした。"), true);
});

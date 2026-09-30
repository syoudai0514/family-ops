import { assertEquals } from "jsr:@std/assert@1";
import {
  completeTaskAndReply,
  type CompletionContext,
  type OpenTask,
  parseCodmonSentReport,
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

function fakeContext(opts: {
  tasks: unknown[];
  defs: Array<{ id: string; code: string }>;
  rpcError?: string;
  rpcData?: unknown;
}) {
  const calls: Call[] = [];
  const replies: Array<{ text: string; quick?: unknown[] }> = [];
  const builder = (table: string) => {
    const filters: Record<string, unknown> = {};
    const chain: Record<string, unknown> = {};
    const self = () => chain;
    for (const m of ["is", "in", "or", "limit", "select"]) chain[m] = self;
    chain.eq = (column: string, value: unknown) => {
      filters[column] = value;
      return chain;
    };
    chain.maybeSingle = () => {
      if (table === "task_definitions") {
        return Promise.resolve({ data: opts.defs.find((d) => d.id === filters.id) ?? null, error: null });
      }
      const task = (opts.tasks as Array<Record<string, unknown>>).find((t) => t.id === filters.id);
      return Promise.resolve({ data: task ? { ...task, revision: 4 } : { revision: 4 }, error: null });
    };
    chain.then = (resolve: (v: unknown) => void) =>
      resolve({ data: table === "task_instances" ? opts.tasks : opts.defs, error: null });
    return chain;
  };
  const client = {
    from: (table: string) => builder(table),
    rpc: (fn: string, args: Record<string, unknown>) => {
      calls.push({ fn, args });
      return Promise.resolve({
        data: opts.rpcError ? null : opts.rpcData ?? null,
        error: opts.rpcError ? { message: opts.rpcError } : null,
      });
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
  { id: "t-c", title: "コドモン送信（将生・詩乃がそろってから）", due_at: null, revision: 3, task_definition_id: "d-c", planned_assignee_id: "u1" },
  { id: "t-d", title: "送り", due_at: null, revision: 3, task_definition_id: "d-d", planned_assignee_id: "u1" },
];
const defs = [{ id: "d-c", code: "codmon_submit" }, { id: "d-d", code: "dropoff" }];

Deno.test("handler: 送りました with Codmon and dropoff open asks which one and completes nothing", async () => {
  const { ctx, calls, replies } = fakeContext({ tasks: rows, defs });
  assertEquals(await tryHandleCompletionReport(ctx, "送りました！"), true);
  assertEquals(calls.length, 0);
  assertEquals(replies[0].text, "どの作業を完了にしますか？");
  const labels = (replies[0].quick as Array<{ label: string }>).map((q) => q.label);
  assertEquals(labels, ["コドモン送信（将生・詩乃がそろってから）", "送り", "今日を見る"]);
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

// Live 2026-09-30 05:43: "コドモン送りました！" was refused with
// "コドモンの入力がそろっていません". Sending Codmon now ends the job.
Deno.test("handler: コドモン送りました closes the submit and the unticked inputs in one command", async () => {
  const { ctx, calls, replies } = fakeContext({ tasks: rows, defs, rpcData: { ok: true, inputs_closed: 4 } });
  assertEquals(await tryHandleCompletionReport(ctx, "コドモン送りました！"), true);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].fn, "server_tx_acknowledge_codmon_submission_v1");
  assertEquals(calls[0].args.p_submit_task_id, "t-c");
  assertEquals(calls[0].args.p_source, "line");
  assertEquals(calls[0].args.p_partner_input_codes, null);
  assertEquals(
    replies[0].text,
    "✓ コドモン送信を完了にしました。\nチェックされていなかった入力4件も、あなたの実施として完了にしました。",
  );
});

// Owner decision 2026-09-30: the sender did every unticked input, except the
// ones they say were already done -- those were the other adult's.
Deno.test("parse Codmon sent: 'Xはやってあった' names inputs done by the other adult", () => {
  assertEquals(parseCodmonSentReport("コドモン送りました！"), { partnerCodes: [], unreadNotes: [] });
  assertEquals(parseCodmonSentReport("コドモン送りました。朝食はやってあった"), {
    partnerCodes: ["codmon_shino_breakfast_input"],
    unreadNotes: [],
  });
  assertEquals(parseCodmonSentReport("朝ごはんと昨日の様子は入力してあったから、コドモン送信した"), {
    partnerCodes: ["codmon_shino_previous_input", "codmon_shino_breakfast_input"],
    unreadNotes: [],
  });
  assertEquals(parseCodmonSentReport("コドモン送った。将生の迎えはママがやってくれてた")?.partnerCodes, ["codmon_masaki_pickup_input"]);
  assertEquals(parseCodmonSentReport("コドモン送った、迎えはやってあった")?.partnerCodes, [
    "codmon_masaki_pickup_input",
    "codmon_shino_pickup_input",
  ]);
  assertEquals(parseCodmonSentReport("コドモン送信済み。全部やってあった")?.partnerCodes.length, 4);
  assertEquals(parseCodmonSentReport("コドモン送りました。バタバタでした"), { partnerCodes: [], unreadNotes: ["バタバタでした"] });
});

Deno.test("parse Codmon sent: questions and other messages are not reports", () => {
  assertEquals(parseCodmonSentReport("コドモン送った？"), null);
  assertEquals(parseCodmonSentReport("コドモンの入力お願い"), null);
  assertEquals(parseCodmonSentReport("送りました"), null);
});

Deno.test("handler: named inputs go to the partner and the reply says who did what", async () => {
  const { ctx, calls, replies } = fakeContext({
    tasks: rows,
    defs,
    rpcData: { ok: true, inputs_closed: 4, inputs_closed_by_partner: 1 },
  });
  assertEquals(await tryHandleCompletionReport(ctx, "コドモン送りました。朝食はやってあった"), true);
  assertEquals(calls[0].fn, "server_tx_acknowledge_codmon_submission_v1");
  assertEquals(calls[0].args.p_partner_input_codes, ["codmon_shino_breakfast_input"]);
  assertEquals(
    replies[0].text,
    "✓ コドモン送信を完了にしました。\nチェックされていなかった入力4件も完了にしました。詩乃：朝食は相手、残りはあなたの実施として記録しています。",
  );
});

Deno.test("handler: an unreadable remark is said back, never guessed", async () => {
  const { ctx, replies } = fakeContext({ tasks: rows, defs, rpcData: { inputs_closed: 2, inputs_closed_by_partner: 0 } });
  await tryHandleCompletionReport(ctx, "コドモン送りました。バタバタでした");
  assertEquals(
    replies[0].text,
    "✓ コドモン送信を完了にしました。\nチェックされていなかった入力2件も、あなたの実施として完了にしました。\n「バタバタでした」はどの入力か分からなかったため、あなたの実施にしています。",
  );
});

Deno.test("handler: nothing to complete when today's Codmon is already done", async () => {
  const { ctx, calls, replies } = fakeContext({ tasks: [rows[1]], defs });
  assertEquals(await tryHandleCompletionReport(ctx, "コドモン送りました"), true);
  assertEquals(calls.length, 0);
  assertEquals(replies[0].text.startsWith("今日の未完了のコドモン送信は見つかりませんでした"), true);
});

Deno.test("handler: the partner can report Codmon sent even though submit is assigned to the other parent", async () => {
  const partnerSubmit = [{ ...rows[0], planned_assignee_id: "u2" }];
  const { ctx, calls } = fakeContext({ tasks: partnerSubmit, defs, rpcData: { inputs_closed: 0 } });
  assertEquals(await tryHandleCompletionReport(ctx, "コドモン送りました"), true);
  assertEquals(calls[0].fn, "server_tx_acknowledge_codmon_submission_v1");
});

Deno.test("handler: other people's ordinary tasks are never offered", async () => {
  const partnerDropoff = [{ ...rows[1], planned_assignee_id: "u2" }];
  const { ctx, calls, replies } = fakeContext({ tasks: partnerDropoff, defs });
  assertEquals(await tryHandleCompletionReport(ctx, "送りました"), true);
  assertEquals(calls.length, 0);
  assertEquals(replies[0].text.startsWith("今日の未完了の作業は見つかりませんでした。"), true);
});

Deno.test("complete (button path): a Codmon submit id is routed by its task code", async () => {
  const { ctx, calls } = fakeContext({ tasks: rows, defs, rpcData: { inputs_closed: 2 } });
  await completeTaskAndReply(ctx, "t-c", { operationId: "op" });
  assertEquals(calls[0].fn, "server_tx_acknowledge_codmon_submission_v1");
});

Deno.test("handler: unrelated text and unmatched hints fall through to the normal flow", async () => {
  const { ctx, calls, replies } = fakeContext({ tasks: rows, defs });
  assertEquals(await tryHandleCompletionReport(ctx, "牛乳買った"), false);
  assertEquals(await tryHandleCompletionReport(ctx, "皿洗いした"), false);
  assertEquals(calls.length + replies.length, 0);
});

Deno.test("complete: an already-finished task says so", async () => {
  const { ctx, replies } = fakeContext({ tasks: [], defs: [], rpcError: "TASK_TERMINAL" });
  await completeTaskAndReply(ctx, "t-x", { title: "夕食", code: null, operationId: "op" });
  assertEquals(replies[0].text, "「夕食」はすでに完了になっています。");
});

Deno.test("handler: nothing open and a bare やった says so, with a link addressed to the sender", async () => {
  Deno.env.set("APP_BASE_URL", "https://example.test/");
  try {
    const { ctx, replies } = fakeContext({ tasks: [], defs: [] });
    assertEquals(await tryHandleCompletionReport(ctx, "やった"), true);
    assertEquals(replies[0].text, "今日の未完了の作業は見つかりませんでした。\nhttps://example.test/today?for=u1");
  } finally {
    Deno.env.delete("APP_BASE_URL");
  }
});

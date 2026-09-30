import { assertEquals } from "jsr:@std/assert@1";
import type { CompletionContext } from "./lineCompletionReport.ts";
import {
  matchShoppingItems,
  parsePurchaseReport,
  reopenShoppingItemAndReply,
  tryHandleShoppingPurchaseReport,
} from "./lineShoppingPurchase.ts";

const TSHIRT = { id: "s-1", title: "将生用のしろい無地のTシャツを買う", revision: 2 };
const MILK = { id: "s-2", title: "牛乳", revision: 1 };

Deno.test("parse: the live messages and natural variants are purchase reports", () => {
  assertEquals(parsePurchaseReport("買ったよ"), { hint: null, all: false });
  assertEquals(parsePurchaseReport("買ってきた"), { hint: null, all: false });
  assertEquals(parsePurchaseReport("Tシャツ買った！"), { hint: "tしゃつ", all: false });
  assertEquals(parsePurchaseReport("牛乳を買いました"), { hint: "牛乳", all: false });
  assertEquals(parsePurchaseReport("全部買った"), { hint: null, all: true });
  assertEquals(parsePurchaseReport("もう牛乳買ってきたよ")?.hint, "牛乳");
});

Deno.test("parse: questions, requests and long or unrelated text are not purchase reports", () => {
  for (const text of [
    "買った？",
    "牛乳買って",
    "何を買えばいい？",
    "明日牛乳2本買ってきて",
    "今日19時から花火大会だから、17時に詩乃を迎えにいく。それと牛乳買った",
    "洗濯した",
    "送りました！",
    "",
  ]) assertEquals(parsePurchaseReport(text), null, text);
});

Deno.test("match: a hint finds the item whether typed in katakana or with the verb stripped", () => {
  const items = [TSHIRT, MILK];
  assertEquals(matchShoppingItems(items, { hint: "tしゃつ", all: false }).map((i) => i.id), ["s-1"]);
  assertEquals(matchShoppingItems(items, { hint: "牛乳", all: false }).map((i) => i.id), ["s-2"]);
  assertEquals(matchShoppingItems(items, { hint: "ぱん", all: false }).length, 0);
  assertEquals(matchShoppingItems(items, { hint: null, all: false }).length, 2);
});

function fakeContext(opts: { items: Array<{ id: string; title: string; revision: number }>; rpcError?: string }) {
  const calls: Array<{ fn: string; args: Record<string, unknown> }> = [];
  const replies: Array<{ text: string; quick?: unknown[] }> = [];
  const builder = () => {
    const chain: Record<string, unknown> = {};
    const self = () => chain;
    for (const m of ["select", "eq", "is", "in", "order", "limit"]) chain[m] = self;
    chain.maybeSingle = () => Promise.resolve({ data: { revision: 7 }, error: null });
    chain.then = (resolve: (v: unknown) => void) => resolve({ data: opts.items, error: null });
    return chain;
  };
  const client = {
    from: () => builder(),
    rpc: (fn: string, args: Record<string, unknown>) => {
      calls.push({ fn, args });
      return Promise.resolve({ data: null, error: opts.rpcError ? { message: opts.rpcError } : null });
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

// Live 2026-09-30 20:39: "買ったよ" produced a title-less "タスクの確認" card.
Deno.test("handler: 買ったよ with one item on the list marks it bought and offers 取り消す", async () => {
  const { ctx, calls, replies } = fakeContext({ items: [TSHIRT] });
  assertEquals(await tryHandleShoppingPurchaseReport(ctx, "買ったよ"), true);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].fn, "server_tx_shopping_action_v2");
  assertEquals(calls[0].args.p_action, "purchased");
  assertEquals(calls[0].args.p_shopping_item_id, "s-1");
  assertEquals(calls[0].args.p_expected_revision, 2);
  assertEquals(replies[0].text, "✓ 「将生用のしろい無地のTシャツを買う」を買った、で記録しました。");
  assertEquals((replies[0].quick as Array<{ data?: string }>)[0].data, "action=shopping_reopen&item_id=s-1&revision=7");
});

Deno.test("handler: a hint picks its item among several", async () => {
  const { ctx, calls } = fakeContext({ items: [TSHIRT, MILK] });
  assertEquals(await tryHandleShoppingPurchaseReport(ctx, "Tシャツ買った！"), true);
  assertEquals(calls.map((c) => c.args.p_shopping_item_id), ["s-1"]);
});

Deno.test("handler: a bare report with several items asks which and changes nothing", async () => {
  const { ctx, calls, replies } = fakeContext({ items: [TSHIRT, MILK] });
  assertEquals(await tryHandleShoppingPurchaseReport(ctx, "買ったよ"), true);
  assertEquals(calls.length, 0);
  assertEquals(replies[0].text, "どれを買いましたか？");
  const data = (replies[0].quick as Array<{ data?: string }>).map((q) => q.data);
  assertEquals(data, ["action=shopping_purchase&item_id=s-1", "action=shopping_purchase&item_id=s-2", "action=shopping_purchase_all&ids=s-1,s-2"]);
});

Deno.test("handler: 全部買った marks every open item", async () => {
  const { ctx, calls, replies } = fakeContext({ items: [TSHIRT, MILK] });
  assertEquals(await tryHandleShoppingPurchaseReport(ctx, "全部買った"), true);
  assertEquals(calls.map((c) => c.args.p_shopping_item_id), ["s-1", "s-2"]);
  assertEquals(replies[0].text, "✓ 2件を買った、で記録しました。\n・将生用のしろい無地のTシャツを買う\n・牛乳");
});

Deno.test("handler: an item that is not on the list, or an empty list, never becomes a draft", async () => {
  const one = fakeContext({ items: [TSHIRT] });
  assertEquals(await tryHandleShoppingPurchaseReport(one.ctx, "パン買った"), true);
  assertEquals(one.calls.length, 0);
  assertEquals(one.replies[0].text, "買い物リストに「ぱん」は見当たりません。\nリストを見て、もう一度送ってください。");
  const none = fakeContext({ items: [] });
  assertEquals(await tryHandleShoppingPurchaseReport(none.ctx, "買ったよ"), true);
  assertEquals(none.replies[0].text, "いま買い物リストに買うものはありません。");
});

Deno.test("handler: a failed purchase says so and a non-report is left alone", async () => {
  const failing = fakeContext({ items: [TSHIRT], rpcError: "INVALID_SHOPPING_TRANSITION" });
  assertEquals(await tryHandleShoppingPurchaseReport(failing.ctx, "買ったよ"), true);
  assertEquals(failing.replies[0].text.startsWith("「将生用のしろい無地のTシャツを買う」を買った、にできませんでした"), true);
  const other = fakeContext({ items: [TSHIRT] });
  assertEquals(await tryHandleShoppingPurchaseReport(other.ctx, "洗濯した"), false);
  assertEquals(other.calls.length, 0);
});

Deno.test("undo: reopens with the revision from the button", async () => {
  const { ctx, calls, replies } = fakeContext({ items: [] });
  await reopenShoppingItemAndReply(ctx, "s-1", 7, "op");
  assertEquals(calls[0].args.p_action, "reopen");
  assertEquals(calls[0].args.p_expected_revision, 7);
  assertEquals(replies[0].text, "元に戻しました（まだ買っていない）。");
});

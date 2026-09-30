import { assertEquals } from "jsr:@std/assert@1";
import { buildShoppingListReply, parseShoppingQuestion, type ShoppingRow } from "./lineShoppingList.ts";

Deno.test("parse: the two live messages and natural variants are list questions", () => {
  assertEquals(parseShoppingQuestion("買い物きている。なに変えば良い?"), { unassignedOnly: false });
  assertEquals(parseShoppingQuestion("パパか担当決まっていない買い物必要なもの出して"), { unassignedOnly: true });
  for (const text of [
    "何買えばいい？",
    "何を買えばいいですか",
    "なに買うんだっけ",
    "店にいる、何を買えばいい？",
    "買い物リスト",
    "買い物リスト見せて",
    "買うもの",
    "買うものある？",
    "買い物で足りないものある?",
  ]) assertEquals(parseShoppingQuestion(text)?.unassignedOnly, false, text);
});

Deno.test("parse: requests to buy, additions and reports are not questions", () => {
  for (const text of [
    "牛乳買って",
    "明日牛乳2本買ってきて",
    "何か買っておいて",
    "買い物を追加したい",
    "買い物お願い",
    "買い物してきた",
    "牛乳買った",
    "今日",
    "買い物",
    "",
    "今日19時から花火大会だから、17時に詩乃を迎えにいく。それと何を買えばいいかも考えないと。それから明日の朝は早いので、パパはお風呂の準備をお願いします。",
  ]) assertEquals(parseShoppingQuestion(text), null, text);
});

const rows: ShoppingRow[] = [
  { title: "バナナ", status: "wanted", assignee_id: null },
  { title: "牛乳", status: "assigned", assignee_id: "papa" },
  { title: "角ウイスキー", status: "assigned", assignee_id: "mama" },
  { title: "オムツ", status: "ordered", assignee_id: null },
  { title: "古い物", status: "purchased", assignee_id: null },
];
const roles = new Map([["papa", "パパ"], ["mama", "ママ"]]);

Deno.test("reply: lists open items with who has them, and counts ordered ones separately", () => {
  const text = buildShoppingListReply(rows, { actorId: "papa", roles, unassignedOnly: false, link: "https://x/shopping" });
  assertEquals(text, [
    "買い物リスト（3件）",
    "・バナナ",
    "・牛乳（あなた）",
    "・角ウイスキー（ママ）",
    "",
    "注文済みで届くのを待っているもの 1件",
    "",
    "▶ 買い物の画面: https://x/shopping",
  ].join("\n"));
});

Deno.test("reply: only the unassigned items when asked", () => {
  const text = buildShoppingListReply(rows, { actorId: "papa", roles, unassignedOnly: true });
  assertEquals(text, "担当が決まっていない買い物（1件）\n・バナナ");
});

Deno.test("reply: empty list and long list", () => {
  assertEquals(buildShoppingListReply([], { actorId: "papa", roles, unassignedOnly: false }), "いま買うものはありません。");
  assertEquals(
    buildShoppingListReply([{ title: "x", status: "wanted", assignee_id: null }], { actorId: "papa", roles, unassignedOnly: true }),
    "担当が決まっていない買い物（1件）\n・x",
  );
  const many: ShoppingRow[] = Array.from({ length: 20 }, (_, i) => ({ title: `品${i}`, status: "wanted", assignee_id: null }));
  const text = buildShoppingListReply(many, { actorId: "papa", roles, unassignedOnly: false });
  assertEquals(text.includes("ほか 5件"), true);
  assertEquals(text.split("\n").length, 17);
});

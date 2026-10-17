import { assertEquals } from "jsr:@std/assert@1";
import { buildQuickShoppingAddedMessage, isQuickShoppingInput, quickShoppingUndoReply } from "./lineQuickShopping.ts";
import type { LineMultiIntentPendingCandidate } from "./lineMultiIntent.ts";

function shopping(title: string, extra: Partial<LineMultiIntentPendingCandidate> = {}): LineMultiIntentPendingCandidate {
  return {
    candidate_id: title, operation_id: crypto.randomUUID(), kind: "shopping", title, source_text: title,
    source_span: null, confidence: 0.9, ambiguous_fields: [], duplicate_match: null, duplicate_decision: null,
    status: "draft", missing_fields: [], action_type: "shopping_item_add", payload: { title }, ...extra,
  } as LineMultiIntentPendingCandidate;
}

Deno.test("plain shopping skips the confirm tap", () => {
  assertEquals(isQuickShoppingInput([shopping("牛乳"), shopping("卵")]), true);
  assertEquals(isQuickShoppingInput([shopping("牛乳"), shopping("x", { status: "cancelled", action_type: "task_create_once" })]), true);
});

Deno.test("anything needing a decision keeps the preview", () => {
  assertEquals(isQuickShoppingInput([]), false);
  assertEquals(isQuickShoppingInput([shopping("牛乳"), shopping("迎え", { action_type: "request_create" })]), false);
  assertEquals(isQuickShoppingInput([shopping("牛乳", { missing_fields: ["品名"] })]), false);
  assertEquals(isQuickShoppingInput([shopping("牛乳", { ambiguous_fields: ["数量"] })]), false);
  assertEquals(isQuickShoppingInput([shopping("牛乳", { duplicate_match: {} as never })]), false);
  assertEquals(isQuickShoppingInput(Array.from({ length: 11 }, (_, i) => shopping(`品${i}`))), false);
});

Deno.test("the reply lists the items and carries the undo postback", () => {
  const message = buildQuickShoppingAddedMessage("pa-1", ["牛乳", "卵"]);
  const json = JSON.stringify(message);
  assertEquals(json.includes("action=undo_quick_shopping&pending_action_id=pa-1"), true);
  assertEquals(json.includes("・牛乳") && json.includes("・卵"), true);
});

Deno.test("undo reply explains what was removed and what was kept", () => {
  assertEquals(quickShoppingUndoReply({ status: "removed", removed: ["牛乳"], kept: ["卵"] }),
    "✓ 買い物リストから外しました: 牛乳\n卵はすでに購入済みなどになっているため、そのままにしています。");
  assertEquals(quickShoppingUndoReply({ status: "cancelled_before_add", removed: ["牛乳"], kept: [] }), "✓ 買い物リストから外しました: 牛乳");
  assertEquals(quickShoppingUndoReply({ status: "already_undone", removed: [], kept: [] }), "取り消し済みです。");
});

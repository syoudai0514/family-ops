// "買ったよ" / "Tシャツ買った！" over LINE marks the shopping-list item bought.
//
// Live 2026-09-30 20:38: after "何を買えばいい？" listed one item, "買ったよ" and
// "Tシャツ買った！" both produced a title-less "タスクの確認" card (予定 / 今日 時刻なし
// / 自分 / タスク) asking to register a NEW task -- the item on the list stayed
// unbought. A purchase report is matched to the list, exactly like a completion
// report is matched to today's tasks (lineCompletionReport.ts).
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";
import type { CompletionContext } from "./lineCompletionReport.ts";

export interface ShoppingCandidate {
  id: string;
  title: string;
  revision: number;
}

export type PurchaseReport = { hint: string | null; all: boolean };

const BUY_VERBS = "買ってきました|買ってきた|買っておいた|買っといた|買いました|買えました|買えた|買った|購入しました|購入した";
const TAIL = "[\\s!！。.よですね〜~]*";
const NOISE = /^(?:もう|さっき|今|ちゃんと|無事|ぜんぶ|全部|全て|すべて)+/u;
const PURCHASE_RE = new RegExp(`^(?:(.{1,20}?)(?:を|は|も|、)?)?(?:${BUY_VERBS})${TAIL}$`, "u");
const ALL_RE = /^(?:全部|ぜんぶ|全て|すべて)/u;

function fold(value: string): string {
  // Katakana -> hiragana so "ティーシャツ" and "てぃーしゃつ" compare equal.
  return value
    .normalize("NFKC")
    .replace(/\s+/gu, "")
    .toLowerCase()
    .replace(/[ァ-ヶ]/gu, (ch) => String.fromCharCode(ch.charCodeAt(0) - 0x60));
}

/** Strict on purpose: only a short, bare "I bought it" sentence qualifies. */
export function parsePurchaseReport(text: string): PurchaseReport | null {
  const t = text.normalize("NFKC").trim();
  if (t.length === 0 || t.length > 30) return null;
  if (/[?？]/u.test(t)) return null;
  const match = t.match(PURCHASE_RE);
  if (!match) return null;
  const raw = (match[1] ?? "").trim();
  if (raw.length === 0) return { hint: null, all: false };
  if (ALL_RE.test(raw) && raw.replace(ALL_RE, "").length === 0) return { hint: null, all: true };
  const hint = fold(raw.replace(NOISE, ""));
  if (hint.length === 0) return { hint: null, all: ALL_RE.test(raw) };
  if (hint.length < 2) return null;
  return { hint, all: false };
}

function core(title: string): string {
  return fold(title).replace(/(?:を|の)?(?:買う|買います|購入|購入する)$/u, "");
}

export function matchShoppingItems(items: ShoppingCandidate[], report: PurchaseReport): ShoppingCandidate[] {
  if (report.all || !report.hint) return items;
  const hint = report.hint;
  return items.filter((item) => fold(item.title).includes(hint) || (core(item.title).length >= 2 && hint.includes(core(item.title))));
}

function quick(label: string, data: string, displayText = label): LineQuickReplyAction {
  return { type: "postback", label: label.length > 20 ? `${label.slice(0, 19)}…` : label, data, displayText: displayText.length > 40 ? `${displayText.slice(0, 39)}…` : displayText };
}

const LIST_QUICK_REPLY: LineQuickReplyAction = { type: "message", label: "買い物リスト", text: "買い物リスト" };

async function loadOpenItems(ctx: CompletionContext): Promise<ShoppingCandidate[] | null> {
  const { data, error } = await ctx.client
    .from("shopping_items")
    .select("id,title,revision")
    .eq("household_id", ctx.householdId)
    .is("test_context_id", null)
    .in("status", ["wanted", "assigned"])
    .order("created_at", { ascending: true })
    .limit(40);
  if (error) {
    console.warn("process-line-inbox: shopping items read failed", (error.message ?? "").slice(0, 120));
    return null;
  }
  return (data ?? []).map((row: Record<string, unknown>) => ({
    id: String(row.id),
    title: String(row.title),
    revision: Number(row.revision),
  }));
}

/** Marks one item bought (canonical RPC) and answers with an undo button. */
export async function purchaseShoppingItemAndReply(
  ctx: CompletionContext,
  item: { id: string; title: string; revision: number },
  operationId: string,
  opts: { quiet?: boolean } = {},
): Promise<boolean> {
  const { error } = await ctx.client.rpc("server_tx_shopping_action_v2", {
    p_actor_id: ctx.actorId,
    p_operation_id: operationId,
    p_shopping_item_id: item.id,
    p_action: "purchased",
    p_expected_revision: item.revision,
    p_reason: null,
  });
  if (error) {
    console.warn("process-line-inbox: LINE purchase failed", { message: (error.message ?? "").slice(0, 120) });
    if (!opts.quiet) await ctx.reply(`「${item.title}」を買った、にできませんでした。すでに状態が変わっている可能性があります。`, [LIST_QUICK_REPLY]);
    return false;
  }
  if (opts.quiet) return true;
  // The undo needs the revision the purchase produced.
  const { data } = await ctx.client.from("shopping_items").select("revision").eq("id", item.id).maybeSingle();
  const revision = Number((data as { revision?: unknown } | null)?.revision);
  const replies: LineQuickReplyAction[] = [];
  if (Number.isFinite(revision)) replies.push(quick("取り消す", `action=shopping_reopen&item_id=${item.id}&revision=${revision}`));
  replies.push(LIST_QUICK_REPLY);
  await ctx.reply(`✓ 「${item.title}」を買った、で記録しました。`, replies);
  return true;
}

/** Button path: the postback carries only the item id, so read its current revision here. */
export async function purchaseShoppingItemByIdAndReply(ctx: CompletionContext, itemId: string, operationId: string): Promise<void> {
  const items = await loadOpenItems(ctx);
  const item = items?.find((candidate) => candidate.id === itemId);
  if (!item) {
    await ctx.reply("この項目はすでに買った、または買い物リストにありません。", [LIST_QUICK_REPLY]);
    return;
  }
  await purchaseShoppingItemAndReply(ctx, item, operationId);
}

export async function reopenShoppingItemAndReply(
  ctx: CompletionContext,
  itemId: string,
  revision: number,
  operationId: string,
): Promise<void> {
  const { error } = await ctx.client.rpc("server_tx_shopping_action_v2", {
    p_actor_id: ctx.actorId,
    p_operation_id: operationId,
    p_shopping_item_id: itemId,
    p_action: "reopen",
    p_expected_revision: revision,
    p_reason: "LINEで取り消し",
  });
  if (error) {
    console.warn("process-line-inbox: LINE shopping reopen failed", { message: (error.message ?? "").slice(0, 120) });
    await ctx.reply("元に戻せませんでした。すでに状態が変わっている可能性があります。買い物の画面で確認してください。", [LIST_QUICK_REPLY]);
    return;
  }
  await ctx.reply("元に戻しました（まだ買っていない）。", [LIST_QUICK_REPLY]);
}

export async function purchaseAllAndReply(ctx: CompletionContext, ids: string[]): Promise<void> {
  const items = (await loadOpenItems(ctx)) ?? [];
  const chosen = items.filter((item) => ids.includes(item.id));
  const bought: string[] = [];
  for (const item of chosen) {
    const opId = await ctx.operationId("line-shopping", ctx.eventId, item.id);
    if (await purchaseShoppingItemAndReply(ctx, item, opId, { quiet: true })) bought.push(item.title);
  }
  await ctx.reply(
    bought.length > 0 ? `✓ ${bought.length}件を買った、で記録しました。\n${bought.map((t) => `・${t}`).join("\n")}` : "買った、にできる項目がありませんでした。",
    [LIST_QUICK_REPLY],
  );
}

/** Answers a purchase report that is already parsed (by the phrase parser or the AI router). */
export async function handlePurchaseReport(ctx: CompletionContext, report: PurchaseReport): Promise<void> {
  const items = await loadOpenItems(ctx);
  if (!items) {
    await ctx.reply("買い物リストを読み込めませんでした。少し待ってからもう一度送ってください。");
    return;
  }
  if (items.length === 0) {
    await ctx.reply("いま買い物リストに買うものはありません。", [LIST_QUICK_REPLY]);
    return;
  }
  const matched = matchShoppingItems(items, report);
  if (matched.length === 0) {
    await ctx.reply(`買い物リストに「${report.hint ?? ""}」は見当たりません。\nリストを見て、もう一度送ってください。`, [LIST_QUICK_REPLY]);
    return;
  }
  if (report.all) {
    await purchaseAllAndReply(ctx, matched.map((item) => item.id));
    return;
  }
  if (matched.length === 1) {
    const opId = await ctx.operationId("line-shopping", ctx.eventId, matched[0].id);
    await purchaseShoppingItemAndReply(ctx, matched[0], opId);
    return;
  }
  const shown = matched.slice(0, 3);
  await ctx.reply("どれを買いましたか？", [
    ...shown.map((item) => quick(item.title, `action=shopping_purchase&item_id=${item.id}`, `買った: ${item.title}`)),
    quick("全部買った", `action=shopping_purchase_all&ids=${matched.slice(0, 6).map((item) => item.id).join(",")}`),
  ]);
}

/** Returns true when the message was a purchase report and has been answered here. */
export async function tryHandleShoppingPurchaseReport(ctx: CompletionContext, text: string): Promise<boolean> {
  const report = parsePurchaseReport(text);
  if (!report) return false;
  await handlePurchaseReport(ctx, report);
  return true;
}

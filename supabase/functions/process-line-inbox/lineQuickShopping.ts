// "牛乳と卵買って" goes straight onto the shopping list: no confirm tap, and the reply
// carries a 取り消す button (owner 2026-10-17). Anything that needs a decision — another
// kind of item, a missing field, a likely duplicate — still gets the normal preview.
import type { LineMultiIntentPendingCandidate } from "./lineMultiIntent.ts";

const MAX_QUICK_ITEMS = 10;
const TEXT = "#202124";
const MUTED = "#667085";

export function isQuickShoppingInput(candidates: LineMultiIntentPendingCandidate[]): boolean {
  const active = candidates.filter((candidate) => candidate.status !== "cancelled");
  return active.length > 0 && active.length <= MAX_QUICK_ITEMS &&
    active.every((candidate) =>
      candidate.action_type === "shopping_item_add" &&
      candidate.missing_fields.length === 0 &&
      candidate.ambiguous_fields.length === 0 &&
      !candidate.duplicate_match &&
      candidate.title.trim().length > 0
    );
}

export function buildQuickShoppingAddedMessage(pendingActionId: string, titles: string[]): Record<string, unknown> {
  return {
    type: "flex",
    altText: `買い物リストに追加: ${titles.join("、")}`,
    contents: {
      type: "bubble",
      size: "kilo",
      body: {
        type: "box",
        layout: "vertical",
        spacing: "xs",
        paddingAll: "12px",
        contents: [
          { type: "text", text: "🛒 買い物リストに追加しました", weight: "bold", size: "sm", color: TEXT, wrap: true },
          ...titles.slice(0, MAX_QUICK_ITEMS).map((title) => ({
            type: "text", text: `・${title}`, size: "sm", color: TEXT, wrap: true,
          })),
          { type: "text", text: "違っていたら取り消せます。", size: "xxs", color: MUTED, margin: "sm" },
        ],
      },
      footer: {
        type: "box",
        layout: "vertical",
        paddingAll: "8px",
        contents: [{
          type: "button", style: "secondary", height: "sm",
          action: {
            type: "postback", label: "取り消す",
            data: `action=undo_quick_shopping&pending_action_id=${pendingActionId}`,
            displayText: "取り消す",
          },
        }],
      },
      styles: { footer: { separator: true } },
    },
  };
}

export type QuickShoppingUndoResult = {
  status: "cancelled_before_add" | "removed" | "already_undone";
  removed: string[];
  kept: string[];
};

export function quickShoppingUndoReply(result: QuickShoppingUndoResult): string {
  if (result.status === "already_undone") return "取り消し済みです。";
  const lines: string[] = [];
  if (result.removed.length > 0) lines.push(`✓ 買い物リストから外しました: ${result.removed.join("、")}`);
  if (result.kept.length > 0) {
    lines.push(`${result.kept.join("、")}はすでに購入済みなどになっているため、そのままにしています。`);
  }
  return lines.length > 0 ? lines.join("\n") : "取り消すものはありませんでした。";
}

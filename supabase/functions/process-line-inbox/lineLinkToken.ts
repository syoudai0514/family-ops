// A link code may arrive inside the message it was shared in ("…このまま送ってね\n<code>"),
// pasted or forwarded whole; exactly one 64-hex run counts.
const LINK_TOKEN_RE = /(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])/gi;

export function findLinkToken(text: string): string | null {
  const matches = text.match(LINK_TOKEN_RE) ?? [];
  return matches.length === 1 ? matches[0].toLowerCase() : null;
}

export const LINK_REJECTED_TEXT = [
  "このコードは使えませんでした（期限切れか、すでに使われたコードです）。",
  "家族に新しいコードを作ってもらい、もう一度このトークに送ってください。",
].join("\n");
export const FOLLOW_UNLINKED_TEXT = [
  "友だち追加ありがとうございます。おうちノートです。",
  "家族から届いた「連携コード」のメッセージを、このトークにそのまま送ってください。送ると連携が完了します。",
].join("\n");
export const NOT_LINKED_TEXT = [
  "おうちノートです。まだ家族との連携が済んでいません。",
  "家族から届いた「連携コード」のメッセージを、このトークにそのまま送ってください。",
].join("\n");

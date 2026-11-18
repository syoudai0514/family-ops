import { assertEquals } from "jsr:@std/assert@1";
import { findLinkToken } from "./lineLinkToken.ts";

const code = "0123456789abcdef".repeat(4);

Deno.test("a code sent alone, forwarded inside its message, or pasted with words is found", () => {
  assertEquals(findLinkToken(code), code);
  assertEquals(findLinkToken(`おうちノートの「ママ（仮）」用のLINE連携コードです。\n有効期限：11/24 21:00\n\n${code}`), code);
  assertEquals(findLinkToken(` ${code.toUpperCase()} `), code);
});

Deno.test("ordinary text, a longer hex run or two codes are not a code", () => {
  assertEquals(findLinkToken("牛乳買って"), null);
  assertEquals(findLinkToken(code + "a"), null);
  assertEquals(findLinkToken(`${code}\n${"f".repeat(64)}`), null);
});

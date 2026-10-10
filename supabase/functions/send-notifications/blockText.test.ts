import { assertEquals } from "jsr:@std/assert@1";
import { itemBlockText } from "./blockText.ts";

Deno.test("a body that opens with the title is not given the title twice", () => {
  assertEquals(itemBlockText("朝のおうちノート", "朝のおうちノート\n\n朝やること\n・薬"), "朝のおうちノート\n\n朝やること\n・薬");
});

Deno.test("a separate title and body are joined; an empty body is the title", () => {
  assertEquals(itemBlockText("お知らせ", "明日は雨です"), "お知らせ\n明日は雨です");
  assertEquals(itemBlockText("お知らせ", ""), "お知らせ");
});

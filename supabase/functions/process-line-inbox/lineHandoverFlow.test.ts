import { assertEquals } from "jsr:@std/assert@1";
import { isHandoverReviewText } from "./lineHandoverFlow.ts";

Deno.test("handover review entry recognizes explicit LINE commands only", () => {
  assertEquals(isHandoverReviewText("共有確認"), true);
  assertEquals(isHandoverReviewText("引き継ぎ確認"), true);
  assertEquals(isHandoverReviewText("確認が必要な共有"), true);
  assertEquals(isHandoverReviewText("共有"), false);
});

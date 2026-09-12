import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import {
  ambiguousAddresseeReply,
  assistantConversationFallback,
  buildAssistantConversationReply,
} from "./lineAssistantConversation.ts";

Deno.test("assistant conversation returns provider advice without performing a family action", async () => {
  const reply = await buildAssistantConversationReply(
    "妻にどう言えば角立たない？",
    () => Promise.resolve(JSON.stringify({ reply: "責めずに、状況とお願いを短く伝えるのがよさそうです。" })),
  );
  assertEquals(reply, "責めずに、状況とお願いを短く伝えるのがよさそうです。");
});

Deno.test("assistant conversation invalid provider output fails safely to a non-mutating fallback", async () => {
  const reply = await buildAssistantConversationReply(
    "これはまだ送らないで",
    () => Promise.resolve("not-json"),
  );
  assertStringIncludes(reply, "送信・通知・登録はしません");
});

Deno.test("assistant conversation fallback preserves explicit no-notify draft-only constraint", () => {
  const reply = assistantConversationFallback("通知しないで下書きだけ作って");
  assertStringIncludes(reply, "相談・下書き");
  assertStringIncludes(reply, "送信・通知・登録はしません");
});

Deno.test("assistant conversation fallback gives useful wording guidance rather than claiming mutation", () => {
  const reply = assistantConversationFallback("妻にどう言えば角立たない？");
  assertStringIncludes(reply, "状況");
  assertStringIncludes(reply, "お願い");
  assertStringIncludes(reply, "相手には送らず");
});

Deno.test("ambiguous addressee asks only the missing boundary and confirms no mutation", () => {
  const reply = ambiguousAddresseeReply();
  assertStringIncludes(reply, "私への相談");
  assertStringIncludes(reply, "家族へのお願い");
  assertStringIncludes(reply, "まだ送らず");
  assertStringIncludes(reply, "通知・登録もしていません");
});


Deno.test("independent review: provider cannot falsely claim a mutation happened", async () => {
  const reply = await buildAssistantConversationReply(
    "妻にどう言えば角立たない？",
    () => Promise.resolve(JSON.stringify({ reply: "ママに送信しました。" })),
  );
  assertStringIncludes(reply, "相手には送らず");
});

Deno.test("independent review: non-mutating provider advice remains accepted", async () => {
  const reply = await buildAssistantConversationReply(
    "妻にどう言えば角立たない？",
    () => Promise.resolve(JSON.stringify({ reply: "理由を短く添えてお願いすると伝わりやすいです。" })),
  );
  assertEquals(reply, "理由を短く添えてお願いすると伝わりやすいです。");
});

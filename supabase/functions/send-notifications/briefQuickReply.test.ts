import { assertEquals } from "jsr:@std/assert@1";
import { buildBriefQuickReply } from "./briefQuickReply.ts";

Deno.test("morning brief offers today / shopping / share, evening adds 入力 first", () => {
  assertEquals(buildBriefQuickReply("daily_brief.v2")?.map((a) => a.label), ["今日", "明日の予定", "買い物", "共有"]);
  assertEquals(buildBriefQuickReply("daily_brief.v2", { evening: true })?.map((a) => a.label), ["入力", "今日", "明日の予定", "買い物", "共有"]);
});

Deno.test("the buttons send text the inbox understands", () => {
  const texts = (buildBriefQuickReply("daily_brief.v2", { evening: true }) ?? []).map((a) => (a as { text: string }).text);
  assertEquals(texts, ["入力", "今日", "明日の予定教えて", "買い物リスト", "共有"]);
  assertEquals((buildBriefQuickReply("codmon.deadline") ?? []).map((a) => (a as { text: string }).text), ["コドモン送りました", "今日"]);
});

Deno.test("other notification types get no buttons here", () => {
  assertEquals(buildBriefQuickReply("routine"), undefined);
  assertEquals(buildBriefQuickReply("request.accepted"), undefined);
});

Deno.test("morning transport consultation stays bound to its date", () => {
  const items = buildBriefQuickReply("daily_brief.v2", { consultDate: "2026-12-31" }) ?? [];
  const button = items.find((action) => action.label === "送り迎えを相談");
  assertEquals(button?.type, "postback");
  const data = new URLSearchParams(button?.type === "postback" ? button.data : "");
  assertEquals(data.get("action"), "transport_consult");
  assertEquals(data.get("date"), "2026-12-31");
});

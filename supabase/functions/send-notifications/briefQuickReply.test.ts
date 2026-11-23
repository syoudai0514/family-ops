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
  const quiet = items.find((action) => action.label === "今日は静かに");
  assertEquals(quiet?.type, "postback");
  const quietData = new URLSearchParams(quiet?.type === "postback" ? quiet.data : "");
  assertEquals(quietData.get("action"), "quiet_today");
  assertEquals(quietData.get("date"), "2026-12-31");
});

Deno.test("bulk actions name the phase and bind the server-issued batch", () => {
  const id = '11111111-1111-4111-8111-111111111111';
  const morning = buildBriefQuickReply('daily_brief.v2', { bulk: { id, phase: 'morning' } }) ?? [];
  assertEquals(morning[0].label, '朝の分ぜんぶOK');
  assertEquals(morning[0].type === 'postback' ? new URLSearchParams(morning[0].data).get('batch_id') : null, id);
  const evening = buildBriefQuickReply('daily_brief.v2', { evening: true, bulk: { id, phase: 'evening' } }) ?? [];
  assertEquals(evening[0].label, '夜の分ぜんぶOK');
  assertEquals(evening[1].label, 'あとで');
  assertEquals(evening[1].type === 'postback' ? evening[1].data : null, 'action=line_bulk_later');
  assertEquals((buildBriefQuickReply('daily_brief.v2', { evening: true, bulk: { id, phase: 'morning' } }) ?? []).some((item) => item.label.includes('ぜんぶOK')), false);
});

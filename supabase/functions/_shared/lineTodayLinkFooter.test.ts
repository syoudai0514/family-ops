import { assertEquals } from "jsr:@std/assert@1";
import { buildTodayLinkFooter } from "./lineMessaging.ts";

// Scheduled briefs and the Codmon reminder were bare text after the
// daily_brief_v2 cutover, so nothing in them led to where the work is done.
Deno.test("brief and Codmon reminder carry a link to Today", () => {
  Deno.env.set("APP_BASE_URL", "https://family-ops-web.vercel.app/");
  try {
    assertEquals(buildTodayLinkFooter("daily_brief.v2"), "▶ 完了・詳細はここから\nhttps://family-ops-web.vercel.app/today");
    assertEquals(buildTodayLinkFooter("codmon.deadline"), "▶ 入力状況を開く\nhttps://family-ops-web.vercel.app/today");
    assertEquals(buildTodayLinkFooter("request.received"), "");
  } finally {
    Deno.env.delete("APP_BASE_URL");
  }
});

Deno.test("no broken relative link when APP_BASE_URL is unset", () => {
  Deno.env.delete("APP_BASE_URL");
  assertEquals(buildTodayLinkFooter("daily_brief.v2"), "");
});

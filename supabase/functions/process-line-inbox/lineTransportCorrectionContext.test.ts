import { assertEquals } from "jsr:@std/assert@1";
import { resolveTransportCorrectionContext } from "./lineTransportCorrectionContext.ts";

const NOW = new Date("2026-10-21T04:24:30Z");
const user = (text: string, at = "2026-10-21T04:22:00Z") => ({ role: "user", text, at });
const assistant = (text: string) => ({ role: "assistant", text, at: "2026-10-21T04:23:00Z" });
const CORRECTION = "だからパパに変えてって言ったじゃん";
const EXPECTED = { kind: "resolved", text: "2026/11/5のお迎えをパパに変更" } as const;

Deno.test("transport context: exact reported conversation keeps pickup and ignores generated wrong-year event titles", () => {
  assertEquals(resolveTransportCorrectionContext([
    user("11/5の迎えを父に変更して。合意済みです。"),
    assistant("予定の確認 11/5(水) 時刻なし 11/5のお迎えを父に変更"),
    user("11/5の迎えを父に変更して。", "2026-10-21T04:22:30Z"),
    assistant("✓ 登録しました。Googleカレンダーにも入れます。"),
    user("11/5の送り迎えおしえて", "2026-10-21T04:24:00Z"),
    assistant("11/5(木) 08:00 送りM 18:20 お迎えM"),
  ], CORRECTION, NOW), EXPECTED);
});

Deno.test("transport context: same-day schedule questions preserve the explicit subject, never create one", () => {
  for (const query of ["11/5の予定教えて", "11/5の送り迎えおしえて", "11/5の送迎を見せてください", "11/5のお迎えは？"]) {
    assertEquals(resolveTransportCorrectionContext([
      user("11/5の迎えを父に変更して"), user(query, "2026-10-21T04:24:00Z"),
    ], CORRECTION, NOW), EXPECTED, query);
    assertEquals(resolveTransportCorrectionContext([user(query)], CORRECTION, NOW), { kind: "clarify" }, query);
  }
});

Deno.test("transport context: only the newest complete directive chooses the subject/date", () => {
  assertEquals(resolveTransportCorrectionContext([
    user("11/5の迎えを父に変更して"),
    user("11/6の送りを母に変更して", "2026-10-21T04:24:00Z"),
  ], CORRECTION, NOW), { kind: "resolved", text: "2026/11/6の送りをパパに変更" });
  assertEquals(resolveTransportCorrectionContext([
    user("11/5の迎えを父に変更して"),
    user("11/5の送りを母に変更して"),
  ], CORRECTION, NOW), { kind: "resolved", text: "2026/11/5の送りをパパに変更" });
});

Deno.test("transport context: date is resolved using each user turn's clock across JST midnight", () => {
  const now = new Date("2026-11-05T15:01:00Z");
  assertEquals(resolveTransportCorrectionContext([
    user("明日の迎えを父に変更して", "2026-11-05T14:59:00Z"),
    user("今日の予定教えて", "2026-11-05T15:00:00Z"),
  ], CORRECTION, now), { kind: "resolved", text: "2026/11/6のお迎えをパパに変更" });
});

Deno.test("transport context: new topics, conflicting queries, incomplete and ambiguous transport reset context", () => {
  for (const next of [
    "11/6の送り迎えおしえて", "今日の予定教えて", "夕食はママにお願い", "買い物を父に変更して",
    "お迎えを父に変更", "11/5のお迎えを変更して", "11/5のお迎えと送りを父に変更して",
    "11/5のお迎えは父でいい？", "11/5のお迎えを父に変更しないで", "パパに変更していい？",
  ]) {
    assertEquals(resolveTransportCorrectionContext([
      user("11/5の迎えを父に変更して"), user(next, "2026-10-21T04:24:00Z"),
      assistant("11/5のお迎えをパパに変更"),
    ], CORRECTION, NOW), { kind: "clarify" }, next);
  }
});

Deno.test("transport context: assistant-only or invalid source data cannot supply a transport subject", () => {
  for (const turns of [
    null, {}, [], [assistant("11/5の迎えを父に変更して")],
    [user("11/5の迎えを父に変更して"), { role: "user", text: "bad", at: "invalid" }],
    [user("11/5の迎えを父に変更して"), { role: "user", text: "", at: "2026-10-21T04:24:00Z" }],
    [user("11/5の迎えを父に変更して"), { role: "unknown", text: "11/5の送りを父に変更して" }],
    [user("11/5の迎えを父に変更して"), null],
    [{ role: "user", text: "11/5の迎えを父に変更して" }],
  ]) assertEquals(resolveTransportCorrectionContext(turns, CORRECTION, NOW), { kind: "clarify" });
});

Deno.test("transport context: stale, future and reversed source clocks do not create current authority", () => {
  for (const at of ["2026-10-21T04:09:29Z", "2026-10-21T04:25:31Z", "invalid"]) {
    assertEquals(resolveTransportCorrectionContext([user("11/5の迎えを父に変更して", at)], CORRECTION, NOW), { kind: "clarify" }, at);
  }
  assertEquals(resolveTransportCorrectionContext([
    user("11/5の迎えを父に変更して", "2026-10-21T04:24:00Z"),
    user("11/5の送りを母に変更して", "2026-10-21T04:23:00Z"),
  ], CORRECTION, NOW), { kind: "clarify" });
});

Deno.test("transport context: later complete directive restores context after another subject", () => {
  assertEquals(resolveTransportCorrectionContext([
    user("11/5の送りを父に変更して"),
    user("買うものは？", "2026-10-21T04:23:00Z"),
    user("11/5の迎えを母に変更して", "2026-10-21T04:24:00Z"),
  ], CORRECTION, NOW), EXPECTED);
});

Deno.test("transport context: target comes only from correction; prior agreement never propagates", () => {
  const turns = [user("11/5の迎えを母に変更して。合意済みです。")];
  assertEquals(resolveTransportCorrectionContext(turns, "だから私に変えて", NOW), { kind: "resolved", text: "2026/11/5のお迎えを私に変更" });
  assertEquals(resolveTransportCorrectionContext(turns, "だから相手に変えて", NOW), { kind: "resolved", text: "2026/11/5のお迎えを相手に変更" });
  assertEquals(resolveTransportCorrectionContext(turns, "だから母に変えて", NOW), { kind: "resolved", text: "2026/11/5のお迎えをママに変更" });
});

Deno.test("transport context: repeated role-only corrections retain an established subject but cannot establish one", () => {
  const turns = [
    user("11/5の迎えを母に変更して。合意済みです。"),
    user(CORRECTION, "2026-10-21T04:23:00Z"),
    assistant("担当変更の確認 11/5(木) お迎え ママ → パパ"),
  ];
  assertEquals(resolveTransportCorrectionContext(turns, CORRECTION, NOW), EXPECTED);
  assertEquals(resolveTransportCorrectionContext([
    ...turns, user("だから私に変えて", "2026-10-21T04:24:00Z"),
  ], "だから母に変えて", NOW), { kind: "resolved", text: "2026/11/5のお迎えをママに変更" });
  assertEquals(resolveTransportCorrectionContext([
    user(CORRECTION), user("11/5の送り迎えおしえて", "2026-10-21T04:24:00Z"),
  ], CORRECTION, NOW), { kind: "clarify" });
  assertEquals(resolveTransportCorrectionContext([
    ...turns, user("夕食はママにお願い", "2026-10-21T04:24:00Z"),
  ], CORRECTION, NOW), { kind: "clarify" });
});

Deno.test("transport context: non-corrections bypass this boundary even with unusable history", () => {
  for (const text of ["11/5の迎えを父に変更して", "11/5の送り迎えおしえて", "買い物をパパに変えて", "確認済みです", "だからパパに変えないでって言ったじゃん"]) {
    assertEquals(resolveTransportCorrectionContext(null, text, NOW), { kind: "not_applicable" }, text);
  }
});

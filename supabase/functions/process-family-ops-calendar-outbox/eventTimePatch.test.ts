import { assertEquals } from "jsr:@std/assert@1";
import { withExclusiveEventTimes } from "./eventTimePatch.ts";

Deno.test("an all-day event that becomes timed clears the old date", () => {
  const body = withExclusiveEventTimes({
    summary: "将生のプール",
    start: { dateTime: "2026-10-10T05:00:00+00:00", timeZone: "Asia/Tokyo" },
    end: { dateTime: "2026-10-10T06:00:00+00:00", timeZone: "Asia/Tokyo" },
  });
  assertEquals(body.start, { dateTime: "2026-10-10T05:00:00+00:00", timeZone: "Asia/Tokyo", date: null });
  assertEquals(body.end, { dateTime: "2026-10-10T06:00:00+00:00", timeZone: "Asia/Tokyo", date: null });
  assertEquals(body.summary, "将生のプール");
});

Deno.test("a timed event that becomes all-day clears the old dateTime", () => {
  const body = withExclusiveEventTimes({ start: { date: "2026-10-10" }, end: { date: "2026-10-11" } });
  assertEquals(body.start, { date: "2026-10-10", dateTime: null, timeZone: null });
  assertEquals(body.end, { date: "2026-10-11", dateTime: null, timeZone: null });
});

Deno.test("a body without times is unchanged", () => {
  assertEquals(withExclusiveEventTimes({ summary: "x" }), { summary: "x" });
});

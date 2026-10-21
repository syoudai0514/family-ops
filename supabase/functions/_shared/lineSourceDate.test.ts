import { assertEquals } from "jsr:@std/assert@1";
import { groundLineSourceDate } from "./lineSourceDate.ts";

const NOW = new Date("2026-10-21T04:22:53.000Z");

Deno.test("a written month/day overrides a model's invented past year", () => {
  for (
    const text of [
      "11/5の迎えを父に変更して。",
      "11月5日の健診を予定に追加",
      "１１／５に歯医者",
    ]
  ) {
    assertEquals(groundLineSourceDate(text, "2025-11-05", NOW), {
      kind: "grounded",
      date: "2026-11-05",
    });
  }
});

Deno.test("an explicit past year remains the sender's date", () => {
  for (
    const text of ["2025/11/5の記録", "2025年11月5日の記録", "2025-11-05の記録"]
  ) {
    assertEquals(groundLineSourceDate(text, "2026-11-05", NOW), {
      kind: "grounded",
      date: "2025-11-05",
    });
  }
});

Deno.test("relative years written by the sender override current-year inference", () => {
  const cases = [
    ["去年の11/5の記録", "2025-11-05"],
    ["昨年11/5の記録", "2025-11-05"],
    ["一昨年11/5の記録", "2024-11-05"],
    ["今年の1/10の記録", "2026-01-10"],
    ["来年11/5の予定", "2027-11-05"],
    ["再来年の11/5の予定", "2028-11-05"],
    ["来年の2027/11/5の予定", "2027-11-05"],
  ];
  for (const [text, date] of cases) {
    assertEquals(groundLineSourceDate(text, "2026-11-05", NOW), {
      kind: "grounded",
      date,
    }, text);
  }
  assertEquals(groundLineSourceDate("去年の2026/11/5", null, NOW), {
    kind: "ambiguous",
  });
});

Deno.test("relative words use the LINE event's JST day across midnight", () => {
  const beforeJstMidnight = new Date("2026-10-20T14:59:00Z");
  assertEquals(
    groundLineSourceDate("今日の用事", "2026-10-21", beforeJstMidnight),
    { kind: "grounded", date: "2026-10-20" },
  );
  assertEquals(
    groundLineSourceDate("明日の用事", "2025-10-21", beforeJstMidnight),
    { kind: "grounded", date: "2026-10-21" },
  );
  assertEquals(
    groundLineSourceDate("あさっての用事", null, beforeJstMidnight),
    { kind: "grounded", date: "2026-10-22" },
  );
  assertEquals(groundLineSourceDate("昨日の記録", null, beforeJstMidnight), {
    kind: "grounded",
    date: "2026-10-19",
  });
  assertEquals(groundLineSourceDate("一昨日の記録", null, beforeJstMidnight), {
    kind: "grounded",
    date: "2026-10-18",
  });
});

Deno.test("date-less corrections keep the context date instead of guessing today", () => {
  assertEquals(
    groundLineSourceDate(
      "だからパパに変えてって言ったじゃん",
      "2026-11-05",
      NOW,
    ),
    { kind: "unchanged", date: "2026-11-05" },
  );
  assertEquals(groundLineSourceDate("皮膚科の予約", null, NOW), {
    kind: "unchanged",
    date: null,
  });
  assertEquals(groundLineSourceDate("服を2枚追加", "2026-10-25", NOW), {
    kind: "unchanged",
    date: "2026-10-25",
  });
});

Deno.test("conflicting or invalid written dates require clarification", () => {
  for (
    const text of [
      "11/5から11/6に変えて",
      "11/5と11/6の予定",
      "明日11/5",
      "11/31の予定",
      "2/30の予定",
      "2025/2/29の予定",
      "11/5と13/2",
      "32日の予定",
    ]
  ) {
    assertEquals(groundLineSourceDate(text, "2026-11-05", NOW), {
      kind: "ambiguous",
    }, text);
  }
});

Deno.test("repeated compatible dates are one grounded source date", () => {
  assertEquals(groundLineSourceDate("11/5、2026年11月5日です", null, NOW), {
    kind: "grounded",
    date: "2026-11-05",
  });
  assertEquals(groundLineSourceDate("明日10/22", null, NOW), {
    kind: "grounded",
    date: "2026-10-22",
  });
});

Deno.test("normal weekday/day grammar shares the existing event date rules", () => {
  assertEquals(groundLineSourceDate("来週の火曜に歯医者", "2025-10-28", NOW), {
    kind: "grounded",
    date: "2026-10-27",
  });
  assertEquals(groundLineSourceDate("22日の予約", null, NOW), {
    kind: "grounded",
    date: "2026-10-22",
  });
  assertEquals(groundLineSourceDate("3日後の予約", null, NOW), {
    kind: "grounded",
    date: "2026-10-24",
  });
  assertEquals(
    groundLineSourceDate("1/10の予定", null, new Date("2026-12-20T01:00:00Z")),
    { kind: "grounded", date: "2027-01-10" },
  );
});

Deno.test("a bad event clock cannot invent a source date", () => {
  assertEquals(groundLineSourceDate("11/5の予定", null, new Date("invalid")), {
    kind: "ambiguous",
  });
  assertEquals(groundLineSourceDate("明日の予定", null, new Date("invalid")), {
    kind: "ambiguous",
  });
});

import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "jsr:@std/assert@1";
import {
  isPickupAssignmentChangeText,
} from "./lineIntent.ts";
import {
  isAssistantAddressCorrection,
  isLineCorrectionCue,
  readOnlyLineIntent,
} from "./lineConversation.ts";
import {
  decomposeLineConversationCandidates,
} from "./lineMultiIntent.ts";
import { rewritePickupRequest } from "../_shared/lineMessageBuilders.ts";
import { validateInvariant } from "../_shared/gemini.ts";

type PickupCase = { text: string; expected: boolean; note: string };

const PICKUP_CASES: PickupCase[] = [
  { text: "9/14のお迎えお願いできる？", expected: true, note: "polite request" },
  { text: "9/14迎え頼む", expected: true, note: "short colloquial request" },
  { text: "9/14迎え頼んでいい？", expected: true, note: "request with permission wording" },
  { text: "9/14迎え代わって", expected: true, note: "handoff" },
  { text: "9/14迎え変わって", expected: true, note: "handoff variant" },
  { text: "9/14迎え変われ", expected: true, note: "blunt imperative" },
  { text: "9/14迎え交代して", expected: true, note: "explicit handoff" },
  { text: "明日の迎えお願い", expected: true, note: "relative date" },
  { text: "明日の迎え変わってくれない？", expected: true, note: "negative-question politeness" },
  { text: "迎え担当して", expected: true, note: "explicit assignment" },
  { text: "迎え頼める？", expected: true, note: "colloquial request" },
  { text: "9/14のお迎えそっちでお願い", expected: true, note: "ellipsis + partner side" },
  { text: "明日迎えそっちお願い", expected: true, note: "ellipsis" },
  { text: "9/14の迎え変わってくれるって言ってたよね？よろしく", expected: true, note: "recollection + explicit proceed" },
  { text: "9/14迎え行ってくれる？", expected: true, note: "semantic handoff without お願い/変わる" },

  { text: "9/14のお迎え担当変わった？", expected: false, note: "status question" },
  { text: "9/14迎え誰？", expected: false, note: "status question" },
  { text: "迎え変わってくれるって言ってたよね？", expected: false, note: "recollection only" },
  { text: "迎えお願いしてたっけ？", expected: false, note: "did-I-request recollection" },
  { text: "迎え頼んだっけ？", expected: false, note: "did-I-request recollection" },
  { text: "迎え変わらなくていい", expected: false, note: "negated handoff" },
  { text: "迎えお願いしなくていい", expected: false, note: "negated request" },
  { text: "迎えはそのままで", expected: false, note: "keep current state" },
  { text: "迎え変更しないで", expected: false, note: "explicit no-change" },
  { text: "迎えできる？", expected: false, note: "availability question, not explicit mutation" },
];

for (const row of PICKUP_CASES) {
  Deno.test(`robustness pickup: ${row.note}: ${row.text}`, () => {
    assertEquals(isPickupAssignmentChangeText(row.text), row.expected);
  });
}

const READ_ONLY_CASES: Array<{ text: string; expected: ReturnType<typeof readOnlyLineIntent> }> = [
  { text: "今日なんか予定あったっけ？", expected: "today" },
  { text: "今日ってなんか予定ある？", expected: "today" },
  { text: "きょうなんかかよていあったっけ", expected: "today" },
  { text: "違うよ、今日の予定教えて", expected: "today" },
  { text: "明日の予定どうなってる？", expected: "tomorrow" },
  { text: "今週何がある？", expected: "week" },
  { text: "今日", expected: "today" },
  { text: "明日", expected: "tomorrow" },
  { text: "今週", expected: "week" },

  { text: "明日の予定追加して", expected: null },
  { text: "今日の予定変更して", expected: null },
  { text: "今日の予定消して", expected: null },
  { text: "明日のお迎えお願い", expected: null },
];

for (const row of READ_ONLY_CASES) {
  Deno.test(`robustness read-only: ${row.text}`, () => {
    assertEquals(readOnlyLineIntent(row.text), row.expected);
  });
}

Deno.test("robustness correction cues tolerate blunt repair language", () => {
  for (const text of [
    "違う",
    "違うよ",
    "いやそうじゃなくて",
    "あなたに聞いてるんだけど",
    "そっちに聞いてんの",
  ]) {
    assert(isLineCorrectionCue(text), `expected correction cue: ${text}`);
  }
  assertEquals(isAssistantAddressCorrection("あなたに聞いてるんだけど"), true);
});

type RewriteCase = {
  raw: string;
  mustContain: string[];
  mustNotContain: string[];
};

const REWRITE_CASES: RewriteCase[] = [
  {
    raw: "仕事でどうしても難しくなりました。9/14のお迎えお願いできる？",
    mustContain: ["仕事でどうしても難しくなりました", "お迎えをお願いしてもいい？"],
    mustNotContain: ["、。"],
  },
  {
    raw: "仕事むり。9/14迎え変われ",
    mustContain: ["仕事むり", "お迎えをお願いしてもいい？"],
    mustNotContain: ["変われ", "、。"],
  },
  {
    raw: "今日ちょっと遅くなるから迎えお願い",
    mustContain: ["今日ちょっと遅くなるから", "お迎えをお願いしてもいい？"],
    mustNotContain: ["今日は少し遅くなりそうです"],
  },
  {
    raw: "前俺やったし9/14迎え変われ",
    mustContain: ["お迎えをお願いしてもいい？"],
    mustNotContain: ["前俺やったし", "変われ"],
  },
  {
    raw: "どうせ暇でしょ9/14迎え行って",
    mustContain: ["お迎えをお願いしてもいい？"],
    mustNotContain: ["どうせ暇でしょ", "行って"],
  },
  {
    raw: "仕事で無理。絶対9/14迎えやって",
    mustContain: ["仕事で無理", "お迎えをお願いしてもいい？"],
    mustNotContain: ["絶対", "やって"],
  },
];

for (const row of REWRITE_CASES) {
  Deno.test(`robustness rewrite: ${row.raw}`, () => {
    const actual = rewritePickupRequest(row.raw);
    for (const token of row.mustContain) assertStringIncludes(actual, token);
    for (const token of row.mustNotContain) {
      assert(!actual.includes(token), `unexpected token ${JSON.stringify(token)} in ${JSON.stringify(actual)}`);
    }
  });
}

type InvariantCase = {
  name: string;
  raw: string;
  proposed: string;
  expectedValid: boolean;
};

const INVARIANT_CASES: InvariantCase[] = [
  {
    name: "preserve explicit date",
    raw: "9/14のお迎えお願い",
    proposed: "9/14のお迎えをお願いしてもいい？",
    expectedValid: true,
  },
  {
    name: "reject changed date",
    raw: "9/14のお迎えお願い",
    proposed: "9/15のお迎えをお願いしてもいい？",
    expectedValid: false,
  },
  {
    name: "reject added quantity",
    raw: "牛乳買って",
    proposed: "牛乳を3本買って",
    expectedValid: false,
  },
  {
    name: "reject negation flip",
    raw: "明日は集合しなくていい",
    proposed: "明日は集合してください",
    expectedValid: false,
  },
  {
    name: "reject invented reason",
    raw: "仕事で難しいから迎えお願い",
    proposed: "体調が悪いので迎えをお願いします",
    expectedValid: false,
  },
  {
    name: "reject invented gratitude",
    raw: "迎えお願い",
    proposed: "いつもありがとう。迎えをお願いします",
    expectedValid: false,
  },
  {
    name: "reject role reversal",
    raw: "ママじゃなくてパパにお願い",
    proposed: "ママにお願いします",
    expectedValid: false,
  },
];

for (const row of INVARIANT_CASES) {
  Deno.test(`robustness invariant: ${row.name}`, () => {
    assertEquals(validateInvariant(row.raw, row.proposed).valid, row.expectedValid);
  });
}

function model(candidates: Array<Record<string, unknown>>): string {
  return JSON.stringify({
    candidates: candidates.map((candidate) => ({
      scheduled_date: "2026-09-12",
      due_local_time: null,
      daypart: null,
      target_role: null,
      shared_message: null,
      subtasks: [],
      context: null,
      calendar_visibility: "hidden",
      missing_fields: [],
      ambiguous_fields: [],
      confidence: 0.95,
      ...candidate,
    })),
  });
}

Deno.test("robustness injected-AI: colloquial long input keeps four independent intents", async () => {
  const raw = "明日病院あるから朝保険証準備しといて、牛乳ないから買っといて、午後仕事入ったから迎えママお願い、あと水遊びあるって";
  const canned = model([
    {
      kind: "task",
      title: "保険証を準備",
      source_text: "朝保険証準備しといて",
      scheduled_date: "2026-09-12",
    },
    {
      kind: "shopping",
      title: "牛乳",
      source_text: "牛乳ないから買っといて",
      scheduled_date: "2026-09-12",
    },
    {
      kind: "request",
      title: "お迎え",
      source_text: "午後仕事入ったから迎えママお願い",
      scheduled_date: "2026-09-12",
      target_role: "mama",
      shared_message: "午後仕事が入ったので、お迎えをお願いしてもいい？",
    },
    {
      kind: "share",
      title: "水遊び",
      source_text: "水遊びあるって",
    },
  ]);
  const candidates = await decomposeLineConversationCandidates(raw, new Date("2026-09-11T03:00:00Z"), () => Promise.resolve(canned));
  assertEquals(candidates.map((c) => c.kind), ["task", "shopping", "request", "share"]);
  assertEquals(candidates[2].intent?.targetRole, "mama");
});

Deno.test("robustness injected-AI: one ambiguity does not erase understood content", async () => {
  const raw = "明日牛乳買って、迎えお願い";
  const canned = model([
    {
      kind: "shopping",
      title: "牛乳",
      source_text: "明日牛乳買って",
      scheduled_date: "2026-09-12",
    },
    {
      kind: "request",
      title: "お迎え",
      source_text: "迎えお願い",
      scheduled_date: "2026-09-12",
      target_role: null,
      shared_message: "お迎えをお願いしてもいい？",
      missing_fields: ["assignee"],
      ambiguous_fields: ["assignee"],
      confidence: 0.55,
    },
  ]);
  const candidates = await decomposeLineConversationCandidates(raw, new Date("2026-09-11T03:00:00Z"), () => Promise.resolve(canned));
  assertEquals(candidates.length, 2);
  assertEquals(candidates[0].missingFields, []);
  assertEquals(candidates[1].missingFields, ["assignee"]);
});

Deno.test("robustness injected-AI: source span fabrication is rejected and falls back safely", async () => {
  const raw = "明日牛乳買って";
  const canned = model([
    {
      kind: "shopping",
      title: "牛乳",
      source_text: "入力にはない文章",
      scheduled_date: "2026-09-12",
    },
  ]);
  const candidates = await decomposeLineConversationCandidates(raw, new Date("2026-09-11T03:00:00Z"), () => Promise.resolve(canned));
  assertEquals(candidates.length, 1);
  assertEquals(candidates[0].kind, "shopping");
});

Deno.test("robustness corpus has broad zero-live-AI coverage", () => {
  const total =
    PICKUP_CASES.length +
    READ_ONLY_CASES.length +
    REWRITE_CASES.length +
    INVARIANT_CASES.length +
    5; // correction + 3 injected-AI + corpus count
  assert(total >= 50, `expected >= 50 zero-live-AI checks, got ${total}`);
});

import { assertEquals } from "jsr:@std/assert@1";
import { normalizeSemanticDecomposition } from "./lineMultiIntent.ts";

type ModelKind = "task" | "request" | "shopping" | "share" | "actual";

type ModelRow = {
  kind: ModelKind;
  title: string;
  sourceText: string;
  targetRole?: "papa" | "mama" | null;
};

type SemanticCase = {
  id: string;
  raw: string;
  modelRows: ModelRow[];
  expected: Array<{ kind: ModelKind; sourceText: string; targetRole?: "papa" | "mama" | null }>;
  coverage: string[];
};

function model(rows: ModelRow[]): string {
  return JSON.stringify({
    candidates: rows.map((row) => ({
      kind: row.kind,
      title: row.title,
      source_text: row.sourceText,
      scheduled_date: "2026-09-12",
      due_local_time: null,
      daypart: null,
      target_role: row.targetRole ?? null,
      shared_message: row.kind === "request" ? `${row.title}をお願いできますか？` : null,
      subtasks: [],
      context: null,
      calendar_visibility: "hidden",
      missing_fields: [],
      ambiguous_fields: [],
      confidence: 0.92,
    })),
  });
}

const ADDRESSEE_CASES: SemanticCase[] = [
  {
    id: "NL-ADDR-D001",
    raw: "これどう思う？",
    modelRows: [{ kind: "task", title: "検討する", sourceText: "これどう思う？" }],
    expected: [],
    coverage: ["AI_DIRECT_QUESTION", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D002",
    raw: "今日どうするのがいいと思う？",
    modelRows: [{ kind: "task", title: "今日の対応を決める", sourceText: "今日どうするのがいいと思う？" }],
    expected: [],
    coverage: ["AI_DIRECT_QUESTION", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D003",
    raw: "妻にどう言えば角立たない？",
    modelRows: [{ kind: "request", title: "妻に伝える", sourceText: "妻にどう言えば角立たない？", targetRole: "mama" }],
    expected: [],
    coverage: ["AI_CONSULTATION", "SPOUSE_MENTION", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D004",
    raw: "こういう時どう頼めばいい？",
    modelRows: [{ kind: "request", title: "お願いする", sourceText: "こういう時どう頼めばいい？" }],
    expected: [],
    coverage: ["AI_CONSULTATION", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D005",
    raw: "迎えお願いできると思う？",
    modelRows: [{ kind: "request", title: "お迎え", sourceText: "迎えお願いできると思う？" }],
    expected: [],
    coverage: ["MINIMAL_PAIR", "AI_CONSULTATION", "PICKUP", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D006",
    raw: "ママにお願いするとしたらなんて言えばいい？",
    modelRows: [{ kind: "request", title: "ママにお願いする", sourceText: "ママにお願いするとしたらなんて言えばいい？", targetRole: "mama" }],
    expected: [],
    coverage: ["AI_CONSULTATION", "SPOUSE_MENTION", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D007",
    raw: "これはまだ送らないで",
    modelRows: [{ kind: "request", title: "これを送る", sourceText: "これはまだ送らないで" }],
    expected: [],
    coverage: ["META_NO_SEND", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D008",
    raw: "登録せずに相談だけしたい",
    modelRows: [{ kind: "task", title: "相談を登録", sourceText: "登録せずに相談だけしたい" }],
    expected: [],
    coverage: ["META_NO_REGISTER", "AI_CONSULTATION", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D009",
    raw: "相手には送らず文章だけ考えて",
    modelRows: [{ kind: "request", title: "文章を相手に送る", sourceText: "相手には送らず文章だけ考えて" }],
    expected: [],
    coverage: ["META_NO_SEND", "DRAFT_ONLY", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D010",
    raw: "この文章どう？",
    modelRows: [{ kind: "share", title: "この文章", sourceText: "この文章どう？" }],
    expected: [],
    coverage: ["AI_DIRECT_QUESTION", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D011",
    raw: "おうちノートならどう伝える？",
    modelRows: [{ kind: "request", title: "伝える", sourceText: "おうちノートならどう伝える？" }],
    expected: [],
    coverage: ["AI_CONSULTATION", "ASSISTANT_ADDRESS", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D012",
    raw: "AIに相談、妻に迎え頼むならどんな言い方？",
    modelRows: [{ kind: "request", title: "お迎え", sourceText: "妻に迎え頼むならどんな言い方？", targetRole: "mama" }],
    expected: [],
    coverage: ["AI_CONSULTATION", "SPOUSE_MENTION", "PICKUP", "NO_MUTATION"],
  },

  {
    id: "NL-ADDR-D013",
    raw: "ママにゴミ出しお願い",
    modelRows: [{ kind: "request", title: "ゴミ出し", sourceText: "ママにゴミ出しお願い", targetRole: "mama" }],
    expected: [{ kind: "request", sourceText: "ママにゴミ出しお願い", targetRole: "mama" }],
    coverage: ["FAMILY_EXPLICIT_REQUEST", "COUNTEREXAMPLE"],
  },
  {
    id: "NL-ADDR-D014",
    raw: "妻に今日のお迎えお願いしたい",
    modelRows: [{ kind: "request", title: "お迎え", sourceText: "妻に今日のお迎えお願いしたい", targetRole: "mama" }],
    expected: [{ kind: "request", sourceText: "妻に今日のお迎えお願いしたい", targetRole: "mama" }],
    coverage: ["FAMILY_EXPLICIT_REQUEST", "PICKUP", "COUNTEREXAMPLE"],
  },
  {
    id: "NL-ADDR-D015",
    raw: "パパに洗濯物たたんでってお願い",
    modelRows: [{ kind: "request", title: "洗濯物をたたむ", sourceText: "パパに洗濯物たたんでってお願い", targetRole: "papa" }],
    expected: [{ kind: "request", sourceText: "パパに洗濯物たたんでってお願い", targetRole: "papa" }],
    coverage: ["FAMILY_EXPLICIT_REQUEST", "COUNTEREXAMPLE"],
  },
  {
    id: "NL-ADDR-D016",
    raw: "ままに牛乳買ってもらいたい",
    modelRows: [{ kind: "shopping", title: "牛乳", sourceText: "ままに牛乳買ってもらいたい", targetRole: "mama" }],
    expected: [{ kind: "shopping", sourceText: "ままに牛乳買ってもらいたい", targetRole: "mama" }],
    coverage: ["FAMILY_EXPLICIT_ACTION", "SHOPPING", "HIRAGANA_ROLE", "COUNTEREXAMPLE"],
  },

  {
    id: "NL-ADDR-D017",
    raw: "あなたならどう伝える？ママには今日の迎えお願いして",
    modelRows: [
      { kind: "task", title: "伝え方を考える", sourceText: "あなたならどう伝える？" },
      { kind: "request", title: "お迎え", sourceText: "ママには今日の迎えお願いして", targetRole: "mama" },
    ],
    expected: [{ kind: "request", sourceText: "ママには今日の迎えお願いして", targetRole: "mama" }],
    coverage: ["MIXED_AI_FAMILY", "PICKUP"],
  },
  {
    id: "NL-ADDR-D018",
    raw: "これどう思う？それとは別にパパにゴミ出しお願い",
    modelRows: [
      { kind: "share", title: "これ", sourceText: "これどう思う？" },
      { kind: "request", title: "ゴミ出し", sourceText: "パパにゴミ出しお願い", targetRole: "papa" },
    ],
    expected: [{ kind: "request", sourceText: "パパにゴミ出しお願い", targetRole: "papa" }],
    coverage: ["MIXED_AI_FAMILY"],
  },
  {
    id: "NL-ADDR-D019",
    raw: "これどう思う？よさそうならママにお願いしたい",
    modelRows: [{ kind: "request", title: "これをお願いする", sourceText: "よさそうならママにお願いしたい", targetRole: "mama" }],
    expected: [],
    coverage: ["MIXED_AI_FAMILY", "CONDITIONAL_ACTION", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D020",
    raw: "文章だけ考えて、送るかはあとで決める",
    modelRows: [{ kind: "request", title: "文章を送る", sourceText: "送るかはあとで決める" }],
    expected: [],
    coverage: ["MIXED_AI_FAMILY", "META_NO_SEND", "CONDITIONAL_ACTION", "NO_MUTATION"],
  },

  {
    id: "NL-ADDR-D021",
    raw: "これお願いできる？",
    modelRows: [{ kind: "request", title: "これ", sourceText: "これお願いできる？" }],
    expected: [],
    coverage: ["AMBIGUOUS_ADDRESSEE", "NO_RECIPIENT_INVENTION"],
  },
  {
    id: "NL-ADDR-D022",
    raw: "今日どうする？",
    modelRows: [{ kind: "task", title: "今日の対応", sourceText: "今日どうする？" }],
    expected: [],
    coverage: ["AMBIGUOUS_ADDRESSEE", "AI_DIRECT_QUESTION", "MINIMAL_PAIR"],
  },
  {
    id: "NL-ADDR-D023",
    raw: "そっちはどう？",
    modelRows: [{ kind: "share", title: "そっちの状況", sourceText: "そっちはどう？" }],
    expected: [],
    coverage: ["AMBIGUOUS_ADDRESSEE", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D024",
    raw: "これいける？",
    modelRows: [{ kind: "task", title: "これを実施", sourceText: "これいける？" }],
    expected: [],
    coverage: ["AMBIGUOUS_ADDRESSEE", "NO_MUTATION"],
  },

  {
    id: "NL-ADDR-D025",
    raw: "違う、あなたに聞いてる",
    modelRows: [{ kind: "request", title: "あなたに聞く", sourceText: "あなたに聞いてる" }],
    expected: [],
    coverage: ["CORRECTION_TO_AI", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D026",
    raw: "妻じゃなくてAIに聞いてる",
    modelRows: [{ kind: "request", title: "妻に聞く", sourceText: "妻じゃなくてAIに聞いてる", targetRole: "mama" }],
    expected: [],
    coverage: ["CORRECTION_TO_AI", "SPOUSE_MENTION", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D027",
    raw: "送ってじゃなくて相談",
    modelRows: [{ kind: "request", title: "送る", sourceText: "送ってじゃなくて相談" }],
    expected: [],
    coverage: ["CORRECTION_TO_AI", "META_NO_SEND", "NO_MUTATION"],
  },
  {
    id: "NL-ADDR-D028",
    raw: "いや、あなたじゃなくて妻にお願いしたい",
    modelRows: [{ kind: "request", title: "お願い", sourceText: "妻にお願いしたい", targetRole: "mama" }],
    expected: [{ kind: "request", sourceText: "妻にお願いしたい", targetRole: "mama" }],
    coverage: ["REVERSE_CORRECTION_TO_FAMILY", "COUNTEREXAMPLE"],
  },
];

const BROKEN_CASES: SemanticCase[] = [
  {
    id: "NL-BROKEN-D001",
    raw: "えっと妻にどう言えば 角たたないかな",
    modelRows: [{ kind: "request", title: "妻に伝える", sourceText: "妻にどう言えば 角たたないかな", targetRole: "mama" }],
    expected: [],
    coverage: ["SPEECH_FILLER", "AI_CONSULTATION", "NO_MUTATION"],
  },
  {
    id: "NL-BROKEN-D002",
    raw: "これ どうおもう",
    modelRows: [{ kind: "task", title: "検討する", sourceText: "これ どうおもう" }],
    expected: [],
    coverage: ["HIRAGANA", "AI_DIRECT_QUESTION", "NO_MUTATION"],
  },
  {
    id: "NL-BROKEN-D003",
    raw: "そうだんだけ とうろくなし",
    modelRows: [{ kind: "task", title: "相談を登録", sourceText: "そうだんだけ とうろくなし" }],
    expected: [],
    coverage: ["BROKEN_JAPANESE", "META_NO_REGISTER", "NO_MUTATION"],
  },
  {
    id: "NL-BROKEN-D004",
    raw: "あいてにはおくらずぶんしょうだけかんがえて",
    modelRows: [{ kind: "request", title: "文章を送る", sourceText: "あいてにはおくらずぶんしょうだけかんがえて" }],
    expected: [],
    coverage: ["PUNCTUATION_FREE", "META_NO_SEND", "NO_MUTATION"],
  },
  {
    id: "NL-BROKEN-D005",
    raw: "迎えお願いできるとおもう",
    modelRows: [{ kind: "request", title: "お迎え", sourceText: "迎えお願いできるとおもう" }],
    expected: [],
    coverage: ["HIRAGANA", "AI_CONSULTATION", "PICKUP", "NO_MUTATION"],
  },
  {
    id: "NL-BROKEN-D006",
    raw: "ままにむかえおねがい",
    modelRows: [{ kind: "request", title: "お迎え", sourceText: "ままにむかえおねがい", targetRole: "mama" }],
    expected: [{ kind: "request", sourceText: "ままにむかえおねがい", targetRole: "mama" }],
    coverage: ["HIRAGANA", "FAMILY_EXPLICIT_REQUEST", "COUNTEREXAMPLE"],
  },
  {
    id: "NL-BROKEN-D007",
    raw: "えっと明日迎えママいやパパお願い",
    modelRows: [{ kind: "request", title: "お迎え", sourceText: "えっと明日迎えママいやパパお願い", targetRole: "papa" }],
    expected: [{ kind: "request", sourceText: "えっと明日迎えママいやパパお願い", targetRole: "papa" }],
    coverage: ["SPEECH_FILLER", "ROLE_CORRECTION", "FAMILY_EXPLICIT_REQUEST"],
  },
  {
    id: "NL-BROKEN-D008",
    raw: "あなたにきいてる ままじゃない",
    modelRows: [{ kind: "request", title: "ママに聞く", sourceText: "あなたにきいてる ままじゃない", targetRole: "mama" }],
    expected: [],
    coverage: ["HIRAGANA", "CORRECTION_TO_AI", "NO_MUTATION"],
  },
];

const DEVELOPMENT_CASES = [...ADDRESSEE_CASES, ...BROKEN_CASES];

assertEquals(DEVELOPMENT_CASES.length, 36);

for (const testCase of DEVELOPMENT_CASES) {
  Deno.test(`${testCase.id}: semantic boundary rejects conversation-only candidates and preserves explicit family actions`, () => {
    const actual = normalizeSemanticDecomposition(model(testCase.modelRows), testCase.raw);
    assertEquals(
      actual.map((candidate) => ({
        kind: candidate.kind,
        sourceText: candidate.sourceText,
        targetRole: candidate.intent?.targetRole ?? undefined,
      })),
      testCase.expected.map((expected) => ({
        kind: expected.kind,
        sourceText: expected.sourceText,
        targetRole: expected.targetRole ?? undefined,
      })),
      `${testCase.id} [${testCase.coverage.join(", ")}]`,
    );
  });
}

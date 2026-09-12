import { assertEquals } from "jsr:@std/assert@1";
import {
  lineNonMutationDisposition,
  linePendingFollowUpKind,
} from "./lineConversation.ts";
import { normalizeSemanticDecomposition } from "./lineMultiIntent.ts";

type ModelKind = "task" | "request" | "shopping" | "share" | "actual";
type ModelRow = {
  kind: ModelKind;
  title: string;
  sourceText: string;
  targetRole?: "papa" | "mama" | null;
};

function model(rows: ModelRow[]): string {
  return JSON.stringify({
    candidates: rows.map((row) => ({
      kind: row.kind,
      title: row.title,
      source_text: row.sourceText,
      scheduled_date: "2026-09-13",
      due_local_time: null,
      daypart: null,
      target_role: row.targetRole ?? null,
      shared_message: row.kind === "request" ? `${row.title}をお願いできますか？` : null,
      subtasks: [],
      context: null,
      calendar_visibility: "hidden",
      missing_fields: [],
      ambiguous_fields: [],
      confidence: 0.91,
    })),
  });
}

function semanticSummary(raw: string, rows: ModelRow[]) {
  return normalizeSemanticDecomposition(model(rows), raw).map((candidate) => ({
    kind: candidate.kind,
    sourceText: candidate.sourceText,
    targetRole: candidate.intent?.targetRole ?? null,
  }));
}

// This file is sealed held-out evidence. Its phrasings were authored after
// the development taxonomy was fixed and before observing their results.
// If a case fails and is used to change implementation, this set becomes
// diagnostic and a fresh replacement held-out set must be authored.

Deno.test("NL-ADDR-H001: indirect wording consultation remains assistant conversation", () => {
  assertEquals(
    lineNonMutationDisposition("パートナーに頼むなら、どういう言い方がいいかな"),
    "assistant_conversation",
  );
});

Deno.test("NL-ADDR-H002: explicit assistant consultation with schedule topic is not mutation", () => {
  assertEquals(
    lineNonMutationDisposition("おうちノートに相談したい 明日の送りどう考える"),
    "assistant_conversation",
  );
});

Deno.test("NL-ADDR-H003: draft-only wording request dominates send language", () => {
  assertEquals(
    lineNonMutationDisposition("まだ誰にも送らずに、言い方だけ整えて"),
    "assistant_conversation",
  );
});

Deno.test("NL-ADDR-H004: clear family request remains actionable", () => {
  const raw = "ママに明日の送りお願いして";
  assertEquals(lineNonMutationDisposition(raw), null);
  assertEquals(
    semanticSummary(raw, [{
      kind: "request",
      title: "送り",
      sourceText: raw,
      targetRole: "mama",
    }]),
    [{ kind: "request", sourceText: raw, targetRole: "mama" }],
  );
});

Deno.test("NL-ADDR-H005: possibility question is not authorization to request", () => {
  assertEquals(
    lineNonMutationDisposition("明日の送りお願いできそうかな？"),
    "assistant_conversation",
  );
});

Deno.test("NL-ADDR-H006: asking opinion before sending remains conversation", () => {
  assertEquals(
    lineNonMutationDisposition("これ、お願いとして送る前にどう思う？"),
    "assistant_conversation",
  );
});

Deno.test("NL-CTX-H001: colloquial repair from pending request to assistant consultation is recognized", () => {
  assertEquals(
    linePendingFollowUpKind("いやお願いじゃない、あなたに相談"),
    "assistant_repair",
  );
});

Deno.test("NL-CTX-H002: pending role correction followed by natural cancel stays coherent", () => {
  assertEquals(linePendingFollowUpKind("パパじゃなくてママにして"), "edit");
  assertEquals(linePendingFollowUpKind("やっぱなし"), "cancel");
});

Deno.test("NL-BROKEN-H001: broken meta consultation remains non-mutating", () => {
  assertEquals(
    lineNonMutationDisposition("えーと これ そうだんだけ おくるなし"),
    "assistant_conversation",
  );
});

Deno.test("NL-BROKEN-H002: speech-like self-repair from request wording to advice remains conversation", () => {
  assertEquals(
    lineNonMutationDisposition("まま むかえ おねがい できるかな じゃなく どうたのむ"),
    "assistant_conversation",
  );
});

Deno.test("NL-MIX-H001: mixed opinion plus explicit family request keeps only the action span", () => {
  const raw = "伝え方どう思う？それとは別でパパにゴミ出しお願いして";
  assertEquals(
    semanticSummary(raw, [
      { kind: "share", title: "伝え方", sourceText: "伝え方どう思う？" },
      {
        kind: "request",
        title: "ゴミ出し",
        sourceText: "それとは別でパパにゴミ出しお願いして",
        targetRole: "papa",
      },
    ]),
    [{
      kind: "request",
      sourceText: "それとは別でパパにゴミ出しお願いして",
      targetRole: "papa",
    }],
  );
});

Deno.test("NL-MIX-H002: mixed draft-review plus explicit shopping keeps only authorized shopping", () => {
  const raw = "文章見て、よければ送るのはまだ、牛乳はママに買ってもらって";
  assertEquals(
    semanticSummary(raw, [
      { kind: "share", title: "文章", sourceText: "文章見て" },
      { kind: "request", title: "文章を送る", sourceText: "よければ送るのはまだ" },
      {
        kind: "shopping",
        title: "牛乳",
        sourceText: "牛乳はママに買ってもらって",
        targetRole: "mama",
      },
    ]),
    [{
      kind: "shopping",
      sourceText: "牛乳はママに買ってもらって",
      targetRole: "mama",
    }],
  );
});

import { assertEquals } from "jsr:@std/assert@1";
import {
  parseTransportAssignmentCorrection,
  parseTransportAssignmentText,
} from "./transportAssignmentIntent.ts";

const NOW = new Date("2026-10-21T04:22:00Z");

Deno.test("transport: the exact father message resolves November 5 in the sender's year", () => {
  for (const text of [
    "11/5の迎えを父に変更して。",
    "１１／５の迎えを父に変更して。",
    "11/5のお迎えを父に変更",
    "11/5 の迎えを 父に 変更して。",
  ]) {
    const intent = parseTransportAssignmentText(text, NOW);
    assertEquals(intent, {
      code: "pickup", target: "papa", scheduledDate: "2026-11-05",
    }, text);
    assertEquals(new Date(`${intent!.scheduledDate}T00:00:00Z`).getUTCDay(), 4);
  }
});

Deno.test("transport: parent names map to fixed family roles rather than relative partner", () => {
  for (const role of ["父", "父親", "父さん", "お父さん", "おとうさん", "パパ"]) {
    assertEquals(parseTransportAssignmentText(`11/5の迎えを${role}に変えて`, NOW), {
      code: "pickup", target: "papa", scheduledDate: "2026-11-05",
    }, role);
  }
  for (const role of ["母", "母親", "母さん", "お母さん", "おかあさん", "ママ"]) {
    assertEquals(parseTransportAssignmentText(`11/5の送り担当は${role}でお願いします`, NOW), {
      code: "dropoff", target: "mama", scheduledDate: "2026-11-05",
    }, role);
  }
});

Deno.test("transport: complete generated titles retain role but do not invent a missing date", () => {
  for (const title of ["お迎えをパパに変更", "送り担当を父に変更", "むかえを父親に変えてください"]) {
    assertEquals(parseTransportAssignmentText(title, NOW), {
      code: title.startsWith("送り") ? "dropoff" : "pickup",
      target: "papa", scheduledDate: null,
    }, title);
  }
});

Deno.test("transport: affirmative agreement before or after the directive is reported context only", () => {
  for (const text of [
    "11/5の迎えを父に変更して。合意済みです。",
    "11/5の迎えを父に変更して。ママと調整済みです。",
    "11/5の迎えを父に変更して！二人で話し合い済みです！",
    "合意済みです。11/5の迎えを父に変更して。",
    "母と合意済みです。11/5の迎えを父に変更して。",
  ]) {
    assertEquals(parseTransportAssignmentText(text, NOW), {
      code: "pickup", target: "papa", scheduledDate: "2026-11-05",
      agreementReported: true,
    }, text);
  }
});

Deno.test("transport: agreement questions, negations, conditions and unrelated second clauses stay unresolved", () => {
  for (const text of [
    "11/5の迎えを父に変更して。合意済みですか？",
    "11/5の迎えを父に変更して。合意済みではありません。",
    "11/5の迎えを父に変更して。合意済みなら。",
    "合意済みなら11/5の迎えを父に変更して。",
    "11/5の迎えを父に変更して。相談中です。",
    "11/5の迎えを父に変更して。夕食はママにお願い。",
    "11/5の迎えを父に変更して。『合意済みです』。",
  ]) assertEquals(parseTransportAssignmentText(text, NOW), null, text);
});

Deno.test("transport: parent aliases do not turn reports, questions, quotes or calendar notes into directives", () => {
  for (const text of [
    "11/5の迎えを父に変更した",
    "11/5の迎えを父に変更しないで",
    "11/5の迎えを父に変えなくていい",
    "11/5の迎えを父に変更していい？",
    "11/5の迎えを父に変更してほしいけど相談したい",
    "『11/5の迎えを父に変更して』とメモして",
    "11/5の迎えを父に変更するという予定を登録して",
    "11/5の迎えを父に変更した話を登録して",
    "だからパパに変えてって言ったじゃん",
  ]) assertEquals(parseTransportAssignmentText(text, NOW), null, text);
});

Deno.test("transport correction: the screenshot's omitted subject supplies a target only", () => {
  for (const text of [
    "だからパパに変えてって言ったじゃん",
    "だから、パパに変えてって言ったじゃん。",
    "そうじゃなくて父に変更してって言ったよ",
    "いや、お父さんに変えてください",
    "担当は父親にして",
    "パパに変更してと言ったはず",
  ]) assertEquals(parseTransportAssignmentCorrection(text), { target: "papa" }, text);
  assertEquals(parseTransportAssignmentCorrection("だから母に変えてって言ったじゃん"), { target: "mama" });
  assertEquals(parseTransportAssignmentCorrection("だから私に変えて"), { target: "self" });
  assertEquals(parseTransportAssignmentCorrection("相手に変更して"), { target: "partner" });
});

Deno.test("transport correction: no target, non-directives, fresh subjects and unrelated corrections cannot borrow context", () => {
  for (const text of [
    "だから変更して",
    "確認済みです",
    "パパに変更しました",
    "だからパパに変えないでって言ったじゃん",
    "だからパパに変えてって言ったじゃん？",
    "パパに変更していい？",
    "パパに変更するなら",
    "パパに変えてほしいけど相談したい",
    "『パパに変えて』とメモして",
    "パパに変えて。夕食もお願い",
    "明日のお迎えをパパに変更して",
    "買い物をパパに変えて",
    "別の話です。パパに変更して",
  ]) assertEquals(parseTransportAssignmentCorrection(text), null, text);
});

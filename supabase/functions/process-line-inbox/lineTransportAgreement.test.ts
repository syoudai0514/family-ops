import { assertEquals } from "jsr:@std/assert@1";
import { parseTransportAgreementFollowUp } from "./lineTransportAgreement.ts";

Deno.test("transport agreement follow-up: the real awkward Japanese and short confirmation reports request explicit review", () => {
  for (
    const text of [
      "確認した済みです",
      "確認済みです",
      "確認しました",
      "はい、確認済みです。",
      "もう確認は済んでいます",
      "確認してあります",
      "調整済みです",
    ]
  ) {
    assertEquals(parseTransportAgreementFollowUp(text), {
      kind: "agreement_reported",
      explicitBilateral: false,
    }, text);
  }
});

Deno.test("transport agreement follow-up: explicit bilateral reports still only request the final confirmation", () => {
  for (
    const text of [
      "妻と話し合い済みです",
      "話し合い済み",
      "2人で調整済みです",
      "二人で合意済み",
      "ママには確認してあります",
      "相手にも確認済みです",
      "はい。夫と話し合いました。",
      "すでにパートナーと話はついています",
      "妻から了承をもらいました",
    ]
  ) {
    assertEquals(parseTransportAgreementFollowUp(text), {
      kind: "agreement_reported",
      explicitBilateral: true,
    }, text);
  }
});

Deno.test("transport agreement follow-up: negation preserves the original owner and cannot become an affirmative report", () => {
  for (
    const text of [
      "まだです",
      "まだ",
      "これからです",
      "未調整です",
      "未合意です",
      "まだ確認していません",
      "妻と話し合いはまだしてない",
      "話し合い済みではありません",
      "確認済みじゃないです",
      "相手とまだ合意できていません",
      "ママとは話してません",
    ]
  ) {
    assertEquals(
      parseTransportAgreementFollowUp(text),
      { kind: "not_agreed" },
      text,
    );
  }
});

Deno.test("transport agreement follow-up: questions, conditions, quoted statements and consultation are not consent reports", () => {
  for (
    const text of [
      "確認済みですか",
      "話し合い済み？",
      "妻と合意済みということですか",
      "確認済みだっけ",
      "確認済みなら変更して",
      "合意できたらお願いします",
      "「確認済みです」",
      "妻が確認済みと言ってます",
      "相談済みです",
      "相談したい",
      "変更してもいいですか",
      "確認しただけです",
      "調整済みじゃない？",
      "未調整ですか",
      "まだ確認してないんだっけ？",
    ]
  ) assertEquals(parseTransportAgreementFollowUp(text), null, text);
});

Deno.test("transport agreement follow-up: bare acknowledgements, old references and unrelated new work are not executable instructions", () => {
  for (
    const text of [
      "はい",
      "OK",
      "うん",
      "よろしく",
      "変更して",
      "キャンセル",
      "昨日は確認済みです",
      "さっきの別件は調整済み",
      "明日の送りはパパです",
      "確認済みです。明日の迎えはママに変更して",
      "別の話です。妻と話し合い済みです",
      "確認済みです。でも変更しないで",
      "",
    ]
  ) assertEquals(parseTransportAgreementFollowUp(text), null, text);
});

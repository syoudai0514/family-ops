/** A report about a pending proposal, never consent to execute a mutation. */
export type TransportAgreementFollowUp =
  | { kind: "agreement_reported"; explicitBilateral: boolean }
  | { kind: "not_agreed" };

const PARTNER = "(?:妻|夫|ママ|パパ|相手|パートナー)";
const BILATERAL =
  `(?:${PARTNER}(?:と(?:は)?|に(?:は|も)?|にも|から)|(?:2人|二人|双方)(?:で|とも))`;
const REPORT = new RegExp(
  `^(?:はい[。.!！、,]?|うん[。.!！、,]?)?(?:もう|すでに|既に)?(${BILATERAL})?` +
    "((?:確認(?:した)?|話し合い|調整|合意|了承)(?:は)?(?:済み|済んで(?:います|ます|いる|る)|済んだ|しました|した|してあります|してある|をもらいました)|話し合いました|話(?:は|が)ついて(?:います|ます|いる))(?:です|だよ|だ|よ)?$",
  "u",
);
const NEGATIVE = new RegExp(
  `^(?:はい[。.!！、,]?|ううん[。.!！、,]?)?(?:まだ|今は)?(?:${BILATERAL})?(?:まだ)?` +
    "(?:(?:確認|話し合い|調整|合意|了承)(?:は|が|も)?(?:まだ)?(?:していません|してません|していない|してない|できていません|できてない|済んでいません|済んでません|済んでいない|済んでない)|(?:確認(?:した)?|話し合い|調整|合意|了承)済み(?:ではありません|じゃありません|ではない|じゃない)|未確認|未調整|未合意|話していません|話してません|話していない|話してない)(?:です|だよ|よ)?$",
  "u",
);

/**
 * Use only with a server-issued transport proposal bound to the same user,
 * household, task, date, requested assignee and observed revision. A match asks
 * the caller to show the final explicit agreement/assignment confirmation; it
 * must not set already_agreed or mutate a task by itself.
 *
 * "確認済み" can mean merely looking at the card, so it is deliberately marked
 * as not explicitly bilateral. Even an explicit report requires the final tap.
 */
export function parseTransportAgreementFollowUp(
  text: string,
): TransportAgreementFollowUp | null {
  const value = text.normalize("NFKC").trim().replace(/\s+/gu, "").replace(
    /[。.!！]+$/u,
    "",
  );
  if (
    !value || value.length > 90 ||
    /[?？「」『』]|(?:ですか|ますか|ましたか|だっけ|でしょうか|かな)$/u.test(
      value,
    )
  ) return null;
  if (
    /^(?:まだ(?:です)?|これから(?:です)?|未確認(?:です)?|未調整(?:です)?|未合意(?:です)?)$/u
      .test(value) || NEGATIVE.test(value)
  ) {
    return { kind: "not_agreed" };
  }
  const report = value.match(REPORT);
  if (!report) return null;
  return {
    kind: "agreement_reported",
    explicitBilateral: Boolean(report[1]) ||
      /^(?:話し合い|合意|了承|話(?:は|が)ついて)/u.test(report[2]),
  };
}

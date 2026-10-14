import { resolveJapanesePickupDate } from "./pickupDate.ts";

export type TransportAssignmentIntent = {
  code: "dropoff" | "pickup";
  target: "self" | "partner" | "papa" | "mama" | null;
  scheduledDate: string | null;
  /** Reported context only; consent must still be selected explicitly in PWA. */
  agreementReported?: true;
};

const DATE =
  "(?:(?:今日|きょう|明日|あした|明後日|あさって|(?:\\d{4}年)?\\d{1,2}月\\d{1,2}日|(?:\\d{4}/)?\\d{1,2}/\\d{1,2}|(?:今週|来週)?[月火水木金土日](?:曜日|曜))(?:の)?(?:朝|夕方|夜)?(?:の)?)?";
const TARGET =
  "私|わたし|自分|僕|ぼく|俺|おれ|相手|パートナー|妻|夫|パパ|ママ|お父さん|お母さん";
const ASSIGNMENT = new RegExp(
  `^${DATE}(?:保育園の)?(送り|おくり|お?迎え|むかえ)(?:の?担当)?(?:は|を)?(?:(${TARGET})(?:に|へ|が))?` +
    "(変更(?:してください|して下さい|してほしい|して欲しい|して|をお願いします|お願いします)?|変えて(?:ください|下さい|ほしい|欲しい)?|して(?:ください|下さい)?|やります|やる|担当します|引き受けます|お願い(?:します)?|代わって(?:ください|下さい)?|交代して(?:ください|下さい)?|変われ)$",
  "u",
);

/** Only an independent directive, never a question, consultation, or report. */
export function parseTransportAssignmentText(
  text: string,
  now = new Date(),
): TransportAssignmentIntent | null {
  const normalized = text.normalize("NFKC").trim()
    .replace(/^(?:別の話(?:です)?|別件(?:です)?)[。.!！、,\n:：]+\s*/u, "")
    .replace(/\s+/gu, "");
  // Strip only a complete affirmative declaration. Conditional statements,
  // questions and consultation are not declarations of prior agreement.
  const agreementPrefix =
    /^(?:すでに|既に)?(?:(?:妻|夫|パパ|ママ|相手|パートナー)と|(?:2人|二人)で)?(?:調整|話し合い|合意)済み(?:です)?[。.!！]+/u;
  const agreementReported = agreementPrefix.test(normalized);
  const value = normalized.replace(agreementPrefix, "").replace(
    /[。.!！]+$/u,
    "",
  );
  if (!value || value.length > 150 || /[?？]/u.test(value)) return null;
  const match = value.match(ASSIGNMENT);
  if (!match) return null;
  const who = match[2];
  const verb = match[3];
  const target = who
    ? /^(?:私|わたし|自分|僕|ぼく|俺|おれ)$/u.test(who)
      ? "self"
      : /^(?:パパ|お父さん)$/u.test(who)
      ? "papa"
      : /^(?:ママ|お母さん)$/u.test(who)
      ? "mama"
      : "partner"
    : /^(?:お願い|代わって|交代して|変われ)/u.test(verb)
    ? "partner"
    : null;
  const dateText = value.replace(/きょう/gu, "今日").replace(/あした/gu, "明日")
    .replace(/あさって/gu, "明後日");
  return {
    code: /^(?:送り|おくり)$/u.test(match[1]) ? "dropoff" : "pickup",
    target,
    scheduledDate: resolveJapanesePickupDate(dateText, now),
    ...(agreementReported ? { agreementReported: true } : {}),
  };
}

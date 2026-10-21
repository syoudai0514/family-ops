import { resolveJapanesePickupDate } from "./pickupDate.ts";

export type TransportAssignmentIntent = {
  code: "dropoff" | "pickup";
  target: "self" | "partner" | "papa" | "mama" | null;
  scheduledDate: string | null;
  /** Reported context only; a later explicit confirmation still selects consent. */
  agreementReported?: true;
};

const DATE =
  "(?:(?:今日|きょう|明日|あした|明後日|あさって|(?:\\d{4}年)?\\d{1,2}月\\d{1,2}日|(?:\\d{4}/)?\\d{1,2}/\\d{1,2}|(?:今週|来週)?[月火水木金土日](?:曜日|曜))(?:の)?(?:朝|夕方|夜)?(?:の)?)?";
const TARGET =
  "私|わたし|自分|僕|ぼく|俺|おれ|相手|パートナー|妻|夫|パパ|ママ|お父さん|おとうさん|父さん|父親|父|お母さん|おかあさん|母さん|母親|母";
const CHANGE =
  "変更(?:してください|して下さい|してほしい|して欲しい|して|をお願いします|お願いします)?|変えて(?:ください|下さい|ほしい|欲しい)?|して(?:ください|下さい)?";
const VERB =
  `${CHANGE}|やります|やる|担当します|引き受けます|お願い(?:します)?|代わって(?:ください|下さい)?|交代して(?:ください|下さい)?|変われ`;
const ASSIGNMENT = new RegExp(
  `^${DATE}(?:保育園の)?(送り|おくり|お?迎え|むかえ)(?:の?担当)?(?:は|を)?(?:(${TARGET})(?:に|へ|が|で))?(${VERB})$`,
  "u",
);
const AGREEMENT =
  "(?:すでに|既に)?(?:(?:妻|夫|パパ|ママ|父|母|お父さん|お母さん|相手|パートナー)と|(?:2人|二人)で)?(?:調整|話し合い|合意)済み(?:です)?";
const AGREEMENT_PREFIX = new RegExp(`^${AGREEMENT}[。.!！]+`, "u");
const AGREEMENT_SUFFIX = new RegExp(`[。.!！]+${AGREEMENT}[。.!！]*$`, "u");

export type TransportAssignmentCorrection = {
  target: Exclude<TransportAssignmentIntent["target"], null>;
};

function targetFor(who: string): TransportAssignmentCorrection["target"] {
  if (/^(?:私|わたし|自分|僕|ぼく|俺|おれ)$/u.test(who)) return "self";
  if (/^(?:パパ|お父さん|おとうさん|父さん|父親|父)$/u.test(who)) return "papa";
  if (/^(?:ママ|お母さん|おかあさん|母さん|母親|母)$/u.test(who)) return "mama";
  return "partner";
}

/**
 * An omitted subject/date can only correct a server-bound transport context.
 * This result supplies neither a date nor a task, and never authorizes a write.
 */
export function parseTransportAssignmentCorrection(
  text: string,
): TransportAssignmentCorrection | null {
  const value = text.normalize("NFKC").trim().replace(/\s+/gu, "")
    .replace(/^(?:(?:だから|なので|そうじゃなくて|そうではなくて|違うよ|違う|ちがうよ|ちがう|いや)[、,。.!！:：]*)+/u, "")
    .replace(/[。.!！]+$/u, "");
  if (!value || value.length > 100 || /[?？「」『』]/u.test(value)) return null;
  const match = value.match(new RegExp(
    `^(?:担当(?:は|を))?(${TARGET})(?:に|へ|で)(?:${CHANGE}|お願い(?:します)?)` +
      "(?:(?:って|と)(?:言った|言ってる|お願いした)(?:じゃん|でしょ|でしょう|よね|よ|はず|んだけど)?|よ|ね)?$",
    "u",
  ));
  return match ? { target: targetFor(match[1]) } : null;
}

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
  const agreementReported = AGREEMENT_PREFIX.test(normalized) ||
    AGREEMENT_SUFFIX.test(normalized);
  const value = normalized.replace(AGREEMENT_PREFIX, "")
    .replace(AGREEMENT_SUFFIX, "").replace(
    /[。.!！]+$/u,
    "",
  );
  if (!value || value.length > 150 || /[?？]/u.test(value)) return null;
  const match = value.match(ASSIGNMENT);
  if (!match) return null;
  const who = match[2];
  const verb = match[3];
  const target = who
    ? targetFor(who)
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

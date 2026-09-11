import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";

export type LineReadOnlyIntent =
  | "today"
  | "tomorrow"
  | "week"
  | "menu"
  | "input"
  | "add"
  | "share"
  | "other";
export type LineCreationKind = "event" | "task" | "request" | "shopping";

function normalized(text: string): string {
  return text.normalize("NFKC").replace(/\s+/g, "").trim();
}

export function isLineCorrectionCue(text: string): boolean {
  const value = normalized(text).replace(/[。.!！?？]+$/g, "");
  return /^(?:違う違う|ちがうちがう|違うよ|ちがうよ|違う|ちがう|いやいや|いや|そうじゃなくて|そうではなくて|そうじゃない|そうじゃないよ)[、,]?/u
    .test(value) || isAssistantAddressCorrection(text);
}

export function isAssistantAddressCorrection(text: string): boolean {
  const value = normalized(text).replace(/[。.!！?？]+$/g, "");
  return /^(?:(?:あなた|おうちノート|AI|そっち)(?:に|へ)?)(?:聞いてる|聞いている|聞いてんの|言ってる|言っている|言ってんの)(?:んだけど|んだよ|んだけどね|よ)?$/u
    .test(value);
}

function normalizedScheduleInquiry(text: string): string {
  return normalized(text)
    .replace(/[。.!！?？]+$/g, "")
    .replace(/^(?:違う違う|ちがうちがう|違うよ|ちがうよ|違う|ちがう|いやいや|いや|そうじゃなくて|そうではなくて|そうじゃない|そうじゃないよ)[、,]*/u, "")
    .replace(/^ただ/u, "")
    .replace(/きょう/gu, "今日")
    .replace(/あした/gu, "明日")
    .replace(/こんしゅう/gu, "今週")
    .replace(/よてい/gu, "予定")
    .replace(/おしえて/gu, "教えて")
    .replace(/しりたい/gu, "知りたい")
    .replace(/みたい/gu, "見たい")
    .replace(/かくにんしたい/gu, "確認したい")
    .replace(/なに/gu, "何")
    // Speech-to-text / thumb-typing often doubles the question particle:
    // "今日なんかかよていあったっけ". Treat it as a read, never a write.
    .replace(/なんかか予定/gu, "なんか予定");
}

function scheduleReadOnlyIntent(text: string): "today" | "tomorrow" | "week" | null {
  const value = normalizedScheduleInquiry(text);
  const match = value.match(/^(今日|明日|今週)(.*)$/u);
  if (!match) return null;
  const kind = match[1] === "今日" ? "today" : match[1] === "明日" ? "tomorrow" : "week";
  const rest = match[2];

  // A phrase that explicitly asks to create/change something is never a read,
  // even if it contains "予定". This guard keeps the expanded conversational
  // grammar fail-closed for mutations.
  if (/(?:追加|登録|作って|作成|変更|消して|削除|送って|お願い|頼んで)/u.test(rest)) return null;

  // Preserve the one-word shortcuts while accepting ordinary questions such
  // as "今日なんか予定あったっけ？" and "今日って何か予定ある？".
  if (rest === "") return kind;
  if (
    /^(?:って)?(?:(?:なんか|何か))?(?:の)?予定(?:は|を|が)?(?:教えて|知りたい|見たい|確認したい|何(?:が)?ある|何だっけ|なんだっけ|ある|あるの|あるっけ|あった|あったっけ|どう|どうなってる|どうだっけ)?(?:だけ)?$/u
      .test(rest)
  ) return kind;
  if (/^(?:って)?(?:なんか|何か)?(?:何(?:が)?ある|どうなってる|どうだっけ)(?:の)?$/u.test(rest)) return kind;
  if (/^(?:って)?(?:なんか|何か)?ある(?:の|っけ)?$/u.test(rest)) return kind;
  return null;
}

export function lineLinkWelcomeText(): string {
  return [
    "✅ LINE連携が完了しました。",
    "",
    "このLINEには、普段の言葉でそのまま話しかけて大丈夫です。",
    "・「今日なんか予定あったっけ？」→ 今日の状況を確認",
    "・「お願いを送りたい」→ 家族へのお願い",
    "・「牛乳買って」→ 買い物の追加候補",
    "・「共有」→ 引き継ぎ・共有",
    "",
    "まずは「今日」と送ってみてください。",
  ].join("\n");
}

export function readOnlyLineIntent(text: string): LineReadOnlyIntent | null {
  const value = normalized(text);
  // These are the literal six LINE entry labels from Q73. They deliberately
  // remain short, so the fixed menu is usable without making people learn a
  // second vocabulary. Each is routed by the worker to a concrete surface.
  if (/^(?:入力|今日の入力|朝の入力|夜の入力)$/.test(value)) return "input";
  if (/^(?:追加|追加したい|登録)$/.test(value)) return "add";
  if (/^(?:共有|引き継ぎ|共有したい)$/.test(value)) return "share";
  if (/^(?:その他|管理|設定)$/.test(value)) return "other";
  if (
    /^(?:メニュー(?:を)?(?:出して|見せて|表示して)?|何(?:が|を)?できる(?:んだっけ|の|こと)?|何できる(?:んだっけ)?|できること(?:は|教えて)?|使い方(?:は|教えて)?|ヘルプ(?:お願い)?)[？?。!！]*$/
      .test(value)
  ) return "menu";

  const scheduleIntent = scheduleReadOnlyIntent(text);
  if (scheduleIntent) return scheduleIntent;
  return null;
}

export function lineCreationStarterKind(text: string): LineCreationKind | null {
  const value = normalized(text).replace(/[。.!！?？]+$/g, "");
  const prefix =
    "(?:(?:パパ|ママ|父|母|お父さん|お母さん|嫁さん|奥さん|妻)に)?(?:(?:今日|明日|明後日)(?:の)?(?:朝|昼|夕方|夜)?(?:の|に)?)?";
  if (
    new RegExp(
      `^${prefix}(?:予定|単発予定)(?:を)?(?:追加|登録)(?:したい|して|する|お願い)?$`,
    ).test(value)
  ) return "event";
  if (
    new RegExp(
      `^${prefix}タスク(?:を)?(?:追加|登録)(?:したい|して|する|お願い)?$`,
    ).test(value)
  ) return "task";
  if (
    new RegExp(
      `^${prefix}(?:お願い|依頼)(?:を)?(?:送りたい|したい|送って|する)$`,
    ).test(value)
  ) return "request";
  if (
    /^(?:買い物|買うもの)(?:を)?(?:追加|登録)(?:したい|して|する|お願い)?$/
      .test(value)
  ) return "shopping";
  return null;
}

const message = (label: string, text = label): LineQuickReplyAction => ({
  type: "message",
  label,
  text,
});

export function menuQuickReplies(): LineQuickReplyAction[] {
  return [
    message("今日", "今日の予定は？"),
    message("入力", "入力"),
    message("追加", "追加したい"),
    message("お願い", "お願いを送りたい"),
    message("共有", "共有"),
    message("その他", "その他"),
  ];
}

export function completionHint(text: string): string {
  return `${text}\n\n💡 次もそのまま文章でOKです。「メニュー」でできることを確認できます。`;
}

export type CompactScheduleEntry = {
  title: string;
  startsAt: string | null;
  roleLabel?: string | null;
  conflict?: boolean;
};

export function formatScheduleReply(
  title: string,
  entries: CompactScheduleEntry[],
): string {
  if (entries.length === 0) return `${title}\n\n予定はありません。`;
  const rendered = entries.slice(0, 8).map((entry) => {
    const time = entry.startsAt
      ? new Intl.DateTimeFormat("ja-JP", {
        timeZone: "Asia/Tokyo",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
      }).format(new Date(entry.startsAt))
      : "終日";
    return `${time} ${entry.title}${
      entry.roleLabel ? `（${entry.roleLabel}）` : ""
    }${entry.conflict ? " ⚠️" : ""}`;
  });
  const remaining = entries.length - rendered.length;
  return `${title}\n\n${rendered.join("\n")}${
    remaining > 0 ? `\nほか${remaining}件` : ""
  }`;
}

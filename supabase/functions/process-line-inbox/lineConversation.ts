import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";

export type LineReadOnlyIntent = "today" | "tomorrow" | "week" | "menu";
export type LineCreationKind = "event" | "task" | "request" | "shopping";

function normalized(text: string): string {
  return text.normalize("NFKC").replace(/\s+/g, "").trim();
}

export function readOnlyLineIntent(text: string): LineReadOnlyIntent | null {
  const value = normalized(text);
  if (
    /^(?:メニュー(?:を)?(?:出して|見せて|表示して)?|何(?:が|を)?できる(?:んだっけ|の|こと)?|何できる(?:んだっけ)?|できること(?:は|教えて)?|使い方(?:は|教えて)?|ヘルプ(?:お願い)?)[？?。!！]*$/
      .test(value)
  ) return "menu";
  if (/^今週(?:の予定(?:は|教えて)?|どうなってる)?[？?]?$/.test(value)) {
    return "week";
  }
  if (/^明日(?:の予定(?:は|教えて)?|なにある)?[？?]?$/.test(value)) {
    return "tomorrow";
  }
  if (/^今日(?:の予定(?:は|教えて)?|なにある)?[？?]?$/.test(value)) {
    return "today";
  }
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
    message("今日の予定", "今日の予定は？"),
    message("明日の予定", "明日の予定教えて"),
    message("今週の予定", "今週の予定は？"),
    message("予定を追加", "予定を追加したい"),
    message("タスク追加", "タスクを追加したい"),
    message("お願い", "お願いを送りたい"),
    message("買い物", "買い物を追加したい"),
    {
      type: "uri",
      label: "PWAを開く",
      uri: `${Deno.env.get("APP_BASE_URL") ?? ""}/today`,
    },
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

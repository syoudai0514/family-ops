import type { LineQuickReplyAction } from '../_shared/lineMessaging.ts';

export type LineReadOnlyIntent = 'today' | 'tomorrow' | 'week' | 'menu';

export function readOnlyLineIntent(text: string): LineReadOnlyIntent | null {
  const value = text.normalize('NFKC').replace(/\s+/g, '').trim();

  // Treat help/menu questions broadly and before natural-language mutation parsing.
  // Phrases such as 「何ができるんだっけ？」 must never become a task like
  // 「機能の確認」. Vague creation starters are also routed to the safe menu
  // instead of creating a fake task whose title is merely 「タスクの追加」.
  if (
    /^(?:メニュー(?:を)?(?:出して|見せて|表示して)?|何(?:が|を)?できる(?:んだっけ|の|こと)?|何できる(?:んだっけ)?|できること(?:は|教えて)?|使い方(?:は|教えて)?|ヘルプ(?:お願い)?)[？?。!！]*$/.test(
      value,
    )
  )
    return 'menu';

  if (
    /^(?:(?:今日|明日|明後日)の?(?:朝|昼|夕方|夜)?(?:に)?)?タスク(?:を)?(?:追加|登録)(?:したい|して|する|お願い)?[？?。!！]*$/.test(
      value,
    ) ||
    /^(?:(?:今日|明日|明後日)の?(?:朝|昼|夕方|夜)?(?:に)?)?(?:お願い|依頼)(?:を)?(?:送りたい|したい|送って|する)[？?。!！]*$/.test(
      value,
    ) ||
    /^(?:買い物|買うもの)(?:を)?(?:追加|登録)(?:したい|して|する|お願い)?[？?。!！]*$/.test(value)
  )
    return 'menu';

  if (/^今週(?:の予定(?:は|教えて)?|どうなってる)?[？?]?$/.test(value)) return 'week';
  if (/^明日(?:の予定(?:は|教えて)?|なにある)?[？?]?$/.test(value)) return 'tomorrow';
  if (/^今日(?:の予定(?:は|教えて)?|なにある)?[？?]?$/.test(value)) return 'today';
  return null;
}

const message = (label: string, text = label): LineQuickReplyAction => ({
  type: 'message',
  label,
  text,
});

export function menuQuickReplies(): LineQuickReplyAction[] {
  // Keep quick replies read-only. Creation shortcuts previously sent vague
  // phrases such as 「明日の夜にタスクを追加したい」, which could be mistaken
  // for an actual task. Registration is intentionally done by sending the
  // concrete natural-language request itself.
  return [
    message('今日の予定', '今日の予定は？'),
    message('明日の予定', '明日の予定教えて'),
    message('今週の予定', '今週の予定は？'),
    { type: 'uri', label: 'PWAを開く', uri: `${Deno.env.get('APP_BASE_URL') ?? ''}/today` },
  ];
}

export function completionHint(text: string): string {
  return `${text}\n\n💡 そのまま文章で話しかけてOKです。できることを見る →「メニュー」`;
}

export type CompactScheduleEntry = {
  title: string;
  startsAt: string | null;
  roleLabel?: string | null;
  conflict?: boolean;
};

export function formatScheduleReply(title: string, entries: CompactScheduleEntry[]): string {
  if (entries.length === 0) return `${title}\n\n予定はありません。`;
  const rendered = entries.slice(0, 8).map((entry) => {
    const time = entry.startsAt
      ? new Intl.DateTimeFormat('ja-JP', {
          timeZone: 'Asia/Tokyo',
          hour: '2-digit',
          minute: '2-digit',
          hour12: false,
        }).format(new Date(entry.startsAt))
      : '終日';
    return `${time} ${entry.title}${entry.roleLabel ? ` ${entry.roleLabel}` : ''}${entry.conflict ? ' ⚠️' : ''}`;
  });
  const remaining = entries.length - rendered.length;
  return `${title}\n\n${rendered.join('\n')}${remaining > 0 ? `\nほか${remaining}件` : ''}`;
}

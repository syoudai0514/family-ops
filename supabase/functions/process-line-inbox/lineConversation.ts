import type { LineQuickReplyAction } from '../_shared/lineMessaging.ts';

export type LineReadOnlyIntent = 'today' | 'tomorrow' | 'week' | 'menu';

export function readOnlyLineIntent(text: string): LineReadOnlyIntent | null {
  const value = text.normalize('NFKC').replace(/\s+/g, '').trim();
  if (/^(?:メニュー|何ができる[？?]?|使い方|ヘルプ)$/.test(value)) return 'menu';
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
  return [
    message('今日の予定', '今日の予定は？'),
    message('明日の予定', '明日の予定教えて'),
    message('今週の予定', '今週の予定は？'),
    message('タスクを追加', '明日の夜にタスクを追加したい'),
    message('お願いを送る', 'ママに明日の朝のお願いを送りたい'),
    message('買い物を追加', '買い物を追加したい'),
    message('朝/夜チェック', '今日の夜のチェックをしたい'),
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

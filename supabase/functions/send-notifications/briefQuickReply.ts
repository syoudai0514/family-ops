// Quick-reply buttons for the scheduled briefs and the Codmon reminder.
//
// Since the daily_brief_v2 cutover (2026-09-04) these were bare text: the old
// routine messages carried 全部完了 / 項目ごとに入力 buttons and the new ones
// carried none (review 2026-09-29 §2-2). Each button here just sends a short
// message the inbox already understands, so there is no new server-side flow:
//   入力              -> the 全部やった / 大体やった / 個別で答える question
//   コドモン送りました -> completes the Codmon job (Requirements §29.1)
//   買い物リスト       -> the shopping list
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";

const say = (label: string, text: string = label): LineQuickReplyAction => ({ type: "message", label, text });

export function buildBriefQuickReply(type: string, opts: { evening?: boolean; previousDay?: string | null; thanks?: { kind: string; id: string } | null; consultDate?: string | null; bulk?: { id: string; phase: 'morning' | 'evening' } | null } = {}): LineQuickReplyAction[] | undefined {
  if (type === "daily_brief.v2") {
    const bulk = opts.bulk && (opts.evening ? opts.bulk.phase === 'evening' : opts.bulk.phase === 'morning')
      ? [{ type: 'postback' as const, label: opts.evening ? '夜の分ぜんぶOK' : '朝の分ぜんぶOK',
        data: new URLSearchParams({ action: 'line_bulk_complete', batch_id: opts.bulk.id }).toString(),
        displayText: opts.evening ? '夜の分ぜんぶOK' : '朝の分ぜんぶOK' }] : [];
    return opts.evening
      ? [...bulk, ...(bulk.length ? [{ type: 'postback' as const, label: 'あとで', data: 'action=line_bulk_later', displayText: 'あとで' }] : []), say("入力"), say("今日"), say("明日の予定", "明日の予定教えて"), say("買い物", "買い物リスト"), say("共有")]
      : [...bulk, ...(opts.previousDay ? [
        { type: 'postback' as const, label: 'ぜんぶ済み', data: new URLSearchParams({ action: 'previous_day_complete', date: opts.previousDay }).toString(), displayText: 'ぜんぶ済み' },
        { type: 'postback' as const, label: 'そのまま', data: 'action=previous_day_keep', displayText: 'そのまま' },
      ] : []), ...(opts.thanks ? [{
        type: 'postback' as const, label: 'ありがとうを送る',
        data: new URLSearchParams({ action: 'send_thanks', kind: opts.thanks.kind, id: opts.thanks.id }).toString(),
        displayText: 'ありがとうを送る',
      }] : []), ...(opts.consultDate ? [{ type: 'postback' as const, label: '送り迎えを相談',
        data: new URLSearchParams({ action: 'transport_consult', date: opts.consultDate }).toString(),
        displayText: '送り迎えを相談',
      }, { type: 'postback' as const, label: '今日は静かに',
        data: new URLSearchParams({ action: 'quiet_today', date: opts.consultDate }).toString(),
        displayText: '今日は静かに',
      }] : []), say("今日"), say("明日の予定", "明日の予定教えて"), say("買い物", "買い物リスト"), say("共有")];
  }
  if (type === "codmon.deadline") {
    return [say("コドモン送りました"), say("今日")];
  }
  return undefined;
}

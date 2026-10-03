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

export function buildBriefQuickReply(type: string, opts: { evening?: boolean; previousDay?: boolean } = {}): LineQuickReplyAction[] | undefined {
  if (type === "daily_brief.v2") {
    return opts.evening
      ? [say("入力"), say("今日"), say("買い物", "買い物リスト"), say("共有")]
      : [...(opts.previousDay ? [say('昨日は全部完了', '昨日のは全部終わっている')] : []), say("今日"), say("買い物", "買い物リスト"), say("共有")];
  }
  if (type === "codmon.deadline") {
    return [say("コドモン送りました"), say("今日")];
  }
  return undefined;
}

// Re-review fix (P1-1/P1-2, docs/adr/0010): the top-level LINE quick-reply
// button set for a bundled routine message
// (docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md #8 "top-level actions": 全部完了
// / 項目ごとに入力 / 今回は不要 / PWAで開く). Split into its own pure/testable
// module for the same reason as process-line-inbox/routineItemFlow.ts.
//
// P1-2: the 今回は不要 button no longer posts
// action=routine_complete&value=skip_incomplete directly -- #8's own text
// requires a confirmation round-trip before a mass-skip mutation ("session
// 全部を一括skipしない。確認を1段挟む"). It now posts
// action=routine_skip_prompt, which process-line-inbox turns into a
// confirm/cancel prompt with NO mutation on this first tap; only the
// confirmed reply calls server_tx_complete_routine_session(...,
// 'skip_incomplete', ...) exactly as before.
//
// P1-1: 項目ごとに入力 was previously PWA-only (superseded design note, see
// docs/adr/0009 decision on this exact point) because per-task quick-reply
// buttons aren't derivable from this bundled payload shape. That is still
// true for the SCHEDULED message itself -- but tapping 項目ごとに入力 now
// starts a server-driven one-item-at-a-time LINE flow
// (process-line-inbox/routineItemFlow.ts) that reads the session live
// rather than from this payload, so the button can be offered here even
// though this function never sees individual task items.
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";
import { buildCheckinLink } from "../_shared/lineMessaging.ts";

// Same design constraint as before (see docs/adr/0009): a
// notification_outbox row's items[] are per-schedule_kind text blocks, not
// one entry per routine session, so these buttons only make sense when the
// bundle maps to exactly one distinct session. Zero or more-than-one
// distinct session in the same bundle (only possible with a non-default
// schedule configuration) falls back to the PWA link(s) already embedded in
// the message text as the only actionable path.
export function buildRoutineQuickReply(sessionIds: string[]): LineQuickReplyAction[] | undefined {
  if (sessionIds.length !== 1) return undefined;
  const sessionId = sessionIds[0];
  return [
    {
      type: "postback",
      label: "全部完了",
      data: `action=routine_complete&session_id=${sessionId}&value=complete_all`,
      displayText: "全部完了",
    },
    {
      type: "postback",
      label: "項目ごとに入力",
      data: `action=routine_item_mode&session_id=${sessionId}`,
      displayText: "項目ごとに入力",
    },
    {
      type: "postback",
      label: "今回は不要",
      data: `action=routine_skip_prompt&session_id=${sessionId}`,
      displayText: "今回は不要",
    },
    {
      type: "uri",
      label: "PWAで開く",
      uri: buildCheckinLink(sessionId),
    },
  ];
}

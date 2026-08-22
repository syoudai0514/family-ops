import type { LineQuickReplyAction } from '../_shared/lineMessaging.ts';

export function missingRoleQuickReplies(
  pendingActionId: string,
): LineQuickReplyAction[] {
  return [
    {
      type: 'postback',
      label: '招待リンクを作る',
      data: `action=create_partner_invite&pending_action_id=${pendingActionId}`,
      displayText: '招待リンクを作る',
    },
    {
      type: 'postback',
      label: '自分に戻す',
      data: `action=update_pending&pending_action_id=${pendingActionId}&field=assignee&value=self`,
      displayText: '自分に戻す',
    },
    {
      type: 'postback',
      label: 'キャンセル',
      data: `action=cancel_pending&pending_action_id=${pendingActionId}`,
      displayText: 'キャンセル',
    },
  ];
}

export function missingRoleRecoveryText(
  role: 'papa' | 'mama',
  partnerHasJoined: boolean,
): string {
  const roleLabel = role === 'papa' ? 'パパ' : 'ママ';
  return partnerHasJoined
    ? `${roleLabel}の役割がまだ決まっていません。下書きは変更していません。PWAの「設定 ＞ 家族」でパパ／ママを割り当ててから、もう一度担当を指定してください。`
    : `${roleLabel}はまだおうちノートに参加していません。下書きはそのままです。招待リンクを作るか、今回は自分の担当に戻してください。`;
}

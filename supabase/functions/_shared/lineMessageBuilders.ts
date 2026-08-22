// LINE rich-message builders are deliberately data-only. They contain only
// opaque canonical IDs in postbacks; private source text and credentials never
// leave the server.
export type AssignmentChangeLineData = {
  requestId: string;
  title: string;
  message: string;
  scope: 'once' | 'this_week';
};

export function rewritePickupRequest(rawText: string): string {
  const reason = /遅/.test(rawText) ? '今日は少し遅くなりそうです。' : '';
  return `${reason}お迎えをお願いしてもいい？`;
}

export function buildPendingActionPreviewFlex(data: {
  pendingActionId: string;
  kindLabel: string;
  title: string;
  scheduleLabel: string;
  targetLabel: string;
  confirmLabel?: string;
}): Record<string, unknown> {
  return {
    type: 'flex',
    altText: `確認: ${data.title}`,
    contents: {
      type: 'bubble',
      body: {
        type: 'box',
        layout: 'vertical',
        spacing: 'md',
        contents: [
          { type: 'text', text: 'この内容でいいですか？', weight: 'bold', size: 'lg' },
          { type: 'text', text: data.kindLabel, size: 'sm', color: '#166B5D', weight: 'bold' },
          { type: 'text', text: data.title, weight: 'bold', size: 'xl', wrap: true },
          {
            type: 'text',
            text: `日時: ${data.scheduleLabel}`,
            size: 'sm',
            color: '#555555',
            wrap: true,
          },
          {
            type: 'text',
            text: `担当: ${data.targetLabel}`,
            size: 'sm',
            color: '#555555',
            wrap: true,
          },
          {
            type: 'text',
            text: '確定するまで登録・送信されません。編集で日付・時間・担当・種別をLINE内で修正できます。',
            size: 'xs',
            wrap: true,
            color: '#777777',
          },
        ],
      },
      footer: {
        type: 'box',
        layout: 'vertical',
        spacing: 'sm',
        contents: [
          {
            type: 'button',
            style: 'primary',
            action: {
              type: 'postback',
              label: data.confirmLabel ?? 'この内容で登録',
              data: `action=confirm_pending&pending_action_id=${data.pendingActionId}`,
              displayText: data.confirmLabel ?? 'この内容で登録',
            },
          },
          {
            type: 'button',
            style: 'secondary',
            action: {
              type: 'postback',
              label: '編集',
              data: `action=edit_pending&pending_action_id=${data.pendingActionId}`,
              displayText: '編集',
            },
          },
          {
            type: 'button',
            style: 'secondary',
            action: {
              type: 'postback',
              label: 'キャンセル',
              data: `action=cancel_pending&pending_action_id=${data.pendingActionId}`,
              displayText: 'キャンセル',
            },
          },
        ],
      },
    },
  };
}

export function buildAssignmentSenderPreviewFlex(data: {
  pendingActionId: string;
  title: string;
  message: string;
  editUrl: string;
  scheduleLabel?: string;
  scope?: 'once' | 'this_week';
}): Record<string, unknown> {
  const scopeLabel = data.scope === 'this_week' ? '今週だけ' : '今回だけ';
  return {
    type: 'flex',
    altText: `この内容で送りますか？ ${data.title}`,
    contents: {
      type: 'bubble',
      body: {
        type: 'box',
        layout: 'vertical',
        spacing: 'md',
        contents: [
          { type: 'text', text: 'この内容で送りますか？', weight: 'bold', size: 'lg' },
          { type: 'text', text: data.title, weight: 'bold', wrap: true },
          { type: 'text', text: data.message, wrap: true, color: '#555555' },
          ...(data.scheduleLabel
            ? [{ type: 'text', text: data.scheduleLabel, size: 'sm', color: '#555555' }]
            : []),
          { type: 'text', text: `${scopeLabel} / 自分 → パートナー`, size: 'xs', color: '#777777' },
        ],
      },
      footer: {
        type: 'box',
        layout: 'vertical',
        spacing: 'sm',
        contents: [
          {
            type: 'button',
            style: 'primary',
            action: {
              type: 'postback',
              label: '送る',
              data: `action=confirm_pending&pending_action_id=${data.pendingActionId}`,
              displayText: '送る',
            },
          },
          {
            type: 'button',
            style: 'secondary',
            action: { type: 'uri', label: '編集', uri: data.editUrl },
          },
          {
            type: 'button',
            style: 'secondary',
            action: {
              type: 'postback',
              label: 'キャンセル',
              data: `action=cancel_pending&pending_action_id=${data.pendingActionId}`,
              displayText: 'キャンセル',
            },
          },
        ],
      },
    },
  };
}

export function buildGeneralRequestFlex(data: {
  title: string;
  message: string;
  acceptPendingActionId: string;
  declinePendingActionId: string;
  scheduleLabel?: string;
}): Record<string, unknown> {
  return {
    type: 'flex',
    altText: `お願い: ${data.title}`,
    contents: {
      type: 'bubble',
      body: {
        type: 'box',
        layout: 'vertical',
        spacing: 'md',
        contents: [
          {
            type: 'text',
            text: 'お願いが届いています',
            weight: 'bold',
            size: 'sm',
            color: '#166B5D',
          },
          { type: 'text', text: data.title, weight: 'bold', size: 'xl', wrap: true },
          ...(data.scheduleLabel
            ? [{ type: 'text', text: data.scheduleLabel, size: 'sm', color: '#555555', wrap: true }]
            : []),
          {
            type: 'text',
            text: data.message || 'お願いできますか？',
            wrap: true,
            color: '#555555',
          },
          {
            type: 'text',
            text: '引き受けるまでタスクにはなりません。',
            size: 'xs',
            wrap: true,
            color: '#777777',
          },
        ],
      },
      footer: {
        type: 'box',
        layout: 'vertical',
        spacing: 'sm',
        contents: [
          {
            type: 'button',
            style: 'primary',
            action: {
              type: 'postback',
              label: '引き受ける',
              data: `action=confirm_pending&pending_action_id=${data.acceptPendingActionId}`,
              displayText: '引き受ける',
            },
          },
          {
            type: 'button',
            style: 'secondary',
            action: {
              type: 'postback',
              label: '今回は難しい',
              data: `action=confirm_pending&pending_action_id=${data.declinePendingActionId}`,
              displayText: '今回は難しい',
            },
          },
        ],
      },
    },
  };
}

export function buildAssignmentRequestFlex(
  data: AssignmentChangeLineData,
): Record<string, unknown> {
  const scopeLabel = data.scope === 'this_week' ? '今週だけ' : '今回だけ';
  return {
    type: 'flex',
    altText: `${scopeLabel}の担当変更のお願い: ${data.title}`,
    contents: {
      type: 'bubble',
      body: {
        type: 'box',
        layout: 'vertical',
        spacing: 'md',
        contents: [
          {
            type: 'text',
            text: `${scopeLabel}の担当変更`,
            weight: 'bold',
            size: 'sm',
            color: '#166B5D',
          },
          { type: 'text', text: data.title, weight: 'bold', size: 'xl', wrap: true },
          {
            type: 'text',
            text: data.message || '担当を引き受けられますか？',
            wrap: true,
            color: '#555555',
          },
          {
            type: 'text',
            text: '「引き受ける」を押すまで、予定の担当は変わりません。',
            size: 'xs',
            wrap: true,
            color: '#777777',
          },
        ],
      },
      footer: {
        type: 'box',
        layout: 'vertical',
        spacing: 'sm',
        contents: [
          {
            type: 'button',
            style: 'primary',
            action: {
              type: 'postback',
              label: '引き受ける',
              data: `action=accept_assignment_change&request_id=${data.requestId}`,
              displayText: '引き受ける',
            },
          },
          {
            type: 'button',
            style: 'secondary',
            action: {
              type: 'postback',
              label: '今日は難しい',
              data: `action=decline_assignment_change&request_id=${data.requestId}`,
              displayText: '今日は難しい',
            },
          },
        ],
      },
    },
  };
}

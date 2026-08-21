// LINE rich-message builders are deliberately data-only.  They contain only
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

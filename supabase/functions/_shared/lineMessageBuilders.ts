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

type FlexFooterAction =
  | { label: string; data: string; primary?: boolean; type?: 'postback' }
  | { label: string; uri: string; primary?: boolean; type: 'uri' };

function flexButton(item: FlexFooterAction): Record<string, unknown> {
  return {
    type: 'button',
    style: item.primary ? 'primary' : 'secondary',
    height: 'sm',
    action:
      item.type === 'uri'
        ? { type: 'uri', label: item.label, uri: item.uri }
        : { type: 'postback', label: item.label, data: item.data, displayText: item.label },
  };
}

/**
 * Keep confirmation actions inside two rows at most. LINE's iPhone client can
 * clip the bottom of a tall bubble even when every individual button uses
 * height=sm, so three vertically stacked buttons are not safe. The primary
 * action stays full width and secondary actions share one horizontal row.
 */
function compactActionFooter(actions: FlexFooterAction[]): Record<string, unknown> {
  const buttons = actions.map(flexButton);
  const contents =
    buttons.length >= 3
      ? [
          buttons[0],
          {
            type: 'box',
            layout: 'horizontal',
            spacing: 'xs',
            contents: buttons.slice(1),
          },
        ]
      : buttons.length === 2
        ? [
            {
              type: 'box',
              layout: 'horizontal',
              spacing: 'xs',
              contents: buttons,
            },
          ]
        : buttons;

  return {
    type: 'box',
    layout: 'vertical',
    spacing: 'xs',
    paddingAll: '6px',
    contents,
  };
}

function compactBody(contents: Record<string, unknown>[]): Record<string, unknown> {
  return {
    type: 'box',
    layout: 'vertical',
    spacing: 'xs',
    paddingAll: '12px',
    contents,
  };
}

export function buildPendingActionPreviewFlex(data: {
  pendingActionId: string;
  kindLabel: string;
  title: string;
  scheduleLabel: string;
  targetLabel: string;
  /** Short, sender-visible structured facts such as a checklist or appointment context. */
  detailLines?: string[];
  confirmLabel?: string;
}): Record<string, unknown> {
  return {
    type: 'flex',
    altText: `確認: ${data.title}`,
    contents: {
      type: 'bubble',
      body: compactBody([
        {
          type: 'text',
          text: `${data.kindLabel}の確認`,
          size: 'sm',
          color: '#166B5D',
          weight: 'bold',
        },
        { type: 'text', text: data.title, weight: 'bold', size: 'lg', wrap: true },
        {
          type: 'text',
          text: `${data.scheduleLabel} ・ ${data.targetLabel}`,
          size: 'sm',
          color: '#555555',
          wrap: true,
        },
        ...(data.detailLines ?? []).slice(0, 2).map((line) => ({
          type: 'text',
          text: line,
          size: 'xs',
          color: '#666666',
          wrap: true,
        })),
      ]),
      footer: compactActionFooter([
        {
          label: data.confirmLabel ?? 'この内容で登録',
          data: `action=confirm_pending&pending_action_id=${data.pendingActionId}`,
          primary: true,
        },
        { label: '編集', data: `action=edit_pending&pending_action_id=${data.pendingActionId}` },
        {
          label: 'キャンセル',
          data: `action=cancel_pending&pending_action_id=${data.pendingActionId}`,
        },
      ]),
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
      body: compactBody([
        { type: 'text', text: 'お願いの確認', weight: 'bold', size: 'sm', color: '#166B5D' },
        { type: 'text', text: data.title, weight: 'bold', size: 'lg', wrap: true },
        { type: 'text', text: data.message, wrap: true, size: 'sm', color: '#555555' },
        ...(data.scheduleLabel
          ? [{ type: 'text', text: data.scheduleLabel, size: 'xs', color: '#666666', wrap: true }]
          : []),
        { type: 'text', text: `${scopeLabel} / 自分 → パートナー`, size: 'xs', color: '#777777' },
      ]),
      footer: compactActionFooter([
        {
          label: '送る',
          data: `action=confirm_pending&pending_action_id=${data.pendingActionId}`,
          primary: true,
        },
        { label: '編集', uri: data.editUrl, type: 'uri' },
        {
          label: 'キャンセル',
          data: `action=cancel_pending&pending_action_id=${data.pendingActionId}`,
        },
      ]),
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
      body: compactBody([
        {
          type: 'text',
          text: 'お願いが届いています',
          weight: 'bold',
          size: 'sm',
          color: '#166B5D',
        },
        { type: 'text', text: data.title, weight: 'bold', size: 'lg', wrap: true },
        ...(data.scheduleLabel
          ? [{ type: 'text', text: data.scheduleLabel, size: 'sm', color: '#555555', wrap: true }]
          : []),
        {
          type: 'text',
          text: data.message || 'お願いできますか？',
          wrap: true,
          size: 'sm',
          color: '#555555',
        },
        {
          type: 'text',
          text: '引き受けるまでタスクにはなりません。',
          size: 'xs',
          wrap: true,
          color: '#777777',
        },
      ]),
      footer: compactActionFooter([
        {
          label: '引き受ける',
          data: `action=confirm_pending&pending_action_id=${data.acceptPendingActionId}`,
          primary: true,
        },
        {
          label: '今回は難しい',
          data: `action=confirm_pending&pending_action_id=${data.declinePendingActionId}`,
        },
      ]),
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
      body: compactBody([
        {
          type: 'text',
          text: `${scopeLabel}の担当変更`,
          weight: 'bold',
          size: 'sm',
          color: '#166B5D',
        },
        { type: 'text', text: data.title, weight: 'bold', size: 'lg', wrap: true },
        {
          type: 'text',
          text: data.message || '担当を引き受けられますか？',
          wrap: true,
          size: 'sm',
          color: '#555555',
        },
        {
          type: 'text',
          text: '「引き受ける」を押すまで、予定の担当は変わりません。',
          size: 'xs',
          wrap: true,
          color: '#777777',
        },
      ]),
      footer: compactActionFooter([
        {
          label: '引き受ける',
          data: `action=accept_assignment_change&request_id=${data.requestId}`,
          primary: true,
        },
        {
          label: '今日は難しい',
          data: `action=decline_assignment_change&request_id=${data.requestId}`,
        },
      ]),
    },
  };
}

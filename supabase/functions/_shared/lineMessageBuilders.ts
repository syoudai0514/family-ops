// LINE rich-message builders are deliberately data-only.  They contain only
// opaque canonical IDs in postbacks; private source text and credentials never
// leave the server.
export type AssignmentChangeLineData = { requestId: string; title: string; message: string; scope: 'once' | 'this_week' };

export function buildAssignmentRequestFlex(data: AssignmentChangeLineData): Record<string, unknown> {
  const scopeLabel = data.scope === 'this_week' ? '今週だけ' : '今回だけ';
  return {
    type: 'flex', altText: `${scopeLabel}の担当変更のお願い: ${data.title}`,
    contents: {
      type: 'bubble', body: { type: 'box', layout: 'vertical', spacing: 'md', contents: [
        { type: 'text', text: `${scopeLabel}の担当変更`, weight: 'bold', size: 'sm', color: '#166B5D' },
        { type: 'text', text: data.title, weight: 'bold', size: 'xl', wrap: true },
        { type: 'text', text: data.message || '担当を引き受けられますか？', wrap: true, color: '#555555' },
        { type: 'text', text: '「引き受ける」を押すまで、予定の担当は変わりません。', size: 'xs', wrap: true, color: '#777777' },
      ] },
      footer: { type: 'box', layout: 'vertical', spacing: 'sm', contents: [
        { type: 'button', style: 'primary', action: { type: 'postback', label: '引き受ける', data: `action=accept_assignment_change&request_id=${data.requestId}`, displayText: '引き受ける' } },
        { type: 'button', style: 'secondary', action: { type: 'postback', label: '今日は難しい', data: `action=decline_assignment_change&request_id=${data.requestId}`, displayText: '今日は難しい' } },
      ] },
    },
  };
}

import { describe, expect, it } from 'vitest';
import { selectedTodosForConfirm } from './EventPlanPage';

describe('Q17 Event human confirmation payload', () => {
  it('omits unselected AI/template candidates and preserves human edits', () => {
    const payload = selectedTodosForConfirm([
      {
        candidate_id: 'template-school-1', source: 'template', title: ' 持ち物を確認 ', scheduled_date: '2026-09-10',
        selected: true, planned_assignee_user_id: '',
      },
      {
        candidate_id: 'ai-1', source: 'ai', title: 'AIだけの候補', scheduled_date: '2026-09-11',
        selected: false, planned_assignee_user_id: 'user-mama',
      },
      {
        candidate_id: 'ai-2', source: 'ai', title: '前日に連絡帳を確認', scheduled_date: '2026-09-12',
        selected: true, planned_assignee_user_id: 'user-papa',
      },
    ]);

    expect(payload).toEqual([
      { candidate_id: 'template-school-1', title: '持ち物を確認', scheduled_date: '2026-09-10', planned_assignee_user_id: null },
      { candidate_id: 'ai-2', title: '前日に連絡帳を確認', scheduled_date: '2026-09-12', planned_assignee_user_id: 'user-papa' },
    ]);
    expect(payload.some((item) => item.candidate_id === 'ai-1')).toBe(false);
  });
});

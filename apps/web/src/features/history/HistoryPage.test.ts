import { describe, expect, it } from 'vitest';
import { createElement } from 'react';
import { render, screen } from '@testing-library/react';
import { completedNextTokyoMorning, EventTrail, historyEntryMatchesDate } from './HistoryPage';
import type { HistoryEntry } from './useHistoryData';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import type { TaskEvent } from '../../lib/types';

function entryFor(date: string): HistoryEntry {
  return { task: { scheduled_date: date }, events: [] } as unknown as HistoryEntry;
}

describe('history occurrence truth', () => {
  it('uses the original occurrence date for yesterday correction filtering', () => {
    expect(historyEntryMatchesDate(entryFor('2026-09-06'), '2026-09-06')).toBe(true);
    expect(historyEntryMatchesDate(entryFor('2026-09-07'), '2026-09-06')).toBe(false);
    expect(historyEntryMatchesDate(entryFor('2026-09-07'), null)).toBe(true);
  });

  it('keeps late registration as audit timing rather than changing the occurrence date', () => {
    expect(completedNextTokyoMorning('2026-09-06', '2026-09-06T14:59:59.000Z')).toBe(false);
    expect(completedNextTokyoMorning('2026-09-06', '2026-09-06T15:00:00.000Z')).toBe(true);
  });
});

const members = [
  { user_id: 'papa-user', family_role: 'papa', profile: null },
  { user_id: 'mama-user', family_role: 'mama', profile: null },
] as HouseholdMemberWithProfile[];

function auditEvent(id: string, eventType: string, payload: TaskEvent['payload'], actorId = 'papa-user'): TaskEvent {
  return {
    id, household_id: 'household', task_instance_id: 'task', actor_id: actorId,
    event_type: eventType as TaskEvent['event_type'], payload, source: 'pwa',
    idempotency_key: null, created_at: '2026-10-13T00:00:00Z',
  };
}

describe('history event details', () => {
  it('shows the situation, additional work, remaining work and next step with their recorder', () => {
    const { container } = render(createElement(EventTrail, { members, events: [auditEvent('progress', 'work_progress_recorded', {
      observed_note: '昨日の分が未洗浄だった', work_done_note: '朝の食器を追加して洗浄を開始',
      remaining_note: '洗浄中。取り出しはまだ', next_step_note: '<script>取り出しを待ってください</script>',
      work_performer_actor_ref_id: 'internal-actor-reference',
    })] }));
    expect(screen.getByText(/状況・補完の記録 · 記録した人: パパ/)).toBeInTheDocument();
    expect(screen.getByText('見つけた状況: 昨日の分が未洗浄だった')).toBeInTheDocument();
    expect(screen.getByText('行ったこと: 朝の食器を追加して洗浄を開始')).toBeInTheDocument();
    expect(screen.getByText('今の状態・残り: 洗浄中。取り出しはまだ')).toBeInTheDocument();
    expect(screen.getByText('次の作業へ: <script>取り出しを待ってください</script>')).toBeInTheDocument();
    expect(container.querySelector('script')).toBeNull();
    expect(container.textContent).not.toMatch(/work_progress_recorded|work_performer_actor_ref_id|internal-actor-reference/);
  });

  it('distinguishes a preparation observer from its unknown performer and hides unfamiliar event codes', () => {
    const { container } = render(createElement(EventTrail, { members, events: [
      auditEvent('ready', 'subtask_completed', { completion_basis: 'observed_ready' }, 'mama-user'),
      auditEvent('reverted', 'subtask_completion_reverted', {}),
      auditEvent('future', 'future_internal_event_code', { observed_note: { internal: 'untrusted-object' } }),
    ] }));
    expect(screen.getByText(/準備済みを確認（実施者不明） · 記録した人: ママ/)).toBeInTheDocument();
    expect(screen.getByText(/チェックを取り消し/)).toBeInTheDocument();
    expect(screen.getByText(/記録の変更/)).toBeInTheDocument();
    expect(container.textContent).not.toMatch(/subtask_completed|subtask_completion_reverted|future_internal_event_code|untrusted-object/);
    expect(container.textContent).not.toContain('実施した人: ママ');
  });
});

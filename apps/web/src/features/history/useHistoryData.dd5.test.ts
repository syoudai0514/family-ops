import { describe, expect, it } from 'vitest';
import { classifyOutcome } from './useHistoryData';
import type { TaskInstance } from '../../lib/types';

function task(overrides: Partial<TaskInstance>): TaskInstance {
  return {
    id: 'task-1',
    household_id: 'household-1',
    task_definition_id: null,
    recurrence_rule_id: null,
    origin: 'manual',
    title: 'テスト',
    category: 'generic',
    routine_phase: 'anytime',
    scheduled_date: '2026-09-03',
    due_at: null,
    planned_assignee_id: 'user-1',
    completion_mode: 'whole',
    status: 'todo',
    actual_completed_by_id: null,
    completed_at: null,
    ...overrides,
  };
}

describe('WP-DD5 History outcome semantics', () => {
  it('distinguishes 今回は不要 from できなかった without audit replay', () => {
    expect(classifyOutcome(task({
      status: 'skipped',
      outcome_reason: 'not_needed_this_occurrence',
    }), '2026-09-03T12:00:00Z')).toBe('not_needed');

    expect(classifyOutcome(task({
      status: 'skipped',
      outcome_reason: 'could_not_do',
    }), '2026-09-03T12:00:00Z')).toBe('could_not_do');

    expect(classifyOutcome(task({
      status: 'skipped',
      outcome_reason: null,
    }), '2026-09-03T12:00:00Z')).toBe('skipped');
  });

  it('keeps waiting orthogonal to overdue/failure classification', () => {
    expect(classifyOutcome(task({
      status: 'todo',
      attention_state: 'waiting',
      due_at: '2026-09-03T08:00:00Z',
      next_check_at: '2026-09-04T00:00:00Z',
    }), '2026-09-03T12:00:00Z')).toBe('waiting');
  });
});

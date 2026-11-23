import { describe, expect, it } from 'vitest';
import type { TaskInstance } from '../../lib/types';
import { classifyOutcome } from './useHistoryData';

describe('unrecorded historical work', () => {
  it('never calls an unrecorded occurrence a failure or completion', () => {
    const task = { status: 'skipped', outcome_reason: 'unrecorded', due_at: null } as TaskInstance;
    expect(classifyOutcome(task, '2026-11-24T00:00:00Z')).toBe('unrecorded');
    expect(classifyOutcome({ ...task, outcome_reason: 'could_not_do' }, '2026-11-24T00:00:00Z')).toBe('could_not_do');
    expect(classifyOutcome({ ...task, outcome_reason: 'not_needed_this_occurrence' }, '2026-11-24T00:00:00Z')).toBe('not_needed');
  });
});

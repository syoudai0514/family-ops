import { beforeEach, describe, expect, it } from 'vitest';
import {
  clearTaskFormDraft,
  readTaskFormDraft,
  saveTaskFormDraft,
  TASK_FORM_DRAFT_KEY,
} from './taskFormDraft';

const draft = {
  title: '保育園の持ち物を準備',
  category: 'childcare',
  scheduledDate: '2026-09-08',
  dueLocalTime: '20:00',
  calendarEndLocalTime: '',
  calendarVisibility: 'hidden' as const,
  assigneeId: 'member-1',
  completionMode: 'subtasks' as const,
  routinePhase: 'evening' as const,
  subtasks: [
    { title: '水筒', required: true },
    { title: 'タオル', required: false },
  ],
};
const scope = { userId: 'user-1', householdId: 'household-1' };

describe('task form draft', () => {
  beforeEach(() => sessionStorage.clear());

  it('restores a create draft after the form is closed', () => {
    saveTaskFormDraft(draft, scope);
    expect(readTaskFormDraft(scope)).toEqual(draft);
  });

  it('clears only when explicitly requested after successful save', () => {
    saveTaskFormDraft(draft, scope);
    clearTaskFormDraft(scope);
    expect(readTaskFormDraft(scope)).toBeNull();
  });

  it('fails closed for corrupt device state', () => {
    sessionStorage.setItem(`${TASK_FORM_DRAFT_KEY}:user-1:household-1`, '{broken');
    expect(readTaskFormDraft(scope)).toBeNull();
  });

  it('keeps personal drafts separate when accounts or households change in the same tab', () => {
    saveTaskFormDraft(draft, scope);
    const otherUser = { ...scope, userId: 'user-2' };
    const otherHousehold = { ...scope, householdId: 'household-2' };
    expect(readTaskFormDraft(otherUser)).toBeNull();
    expect(readTaskFormDraft(otherHousehold)).toBeNull();
    saveTaskFormDraft({ ...draft, title: '別の家庭の予定' }, otherHousehold);
    clearTaskFormDraft(otherHousehold);
    expect(readTaskFormDraft(scope)).toEqual(draft);
  });

  it('does not attribute legacy or unauthenticated drafts to the current user', () => {
    sessionStorage.setItem('family-ops:task-form-draft:v1', JSON.stringify(draft));
    expect(readTaskFormDraft(scope)).toBeNull();
    saveTaskFormDraft(draft, null);
    expect(readTaskFormDraft(null)).toBeNull();
    expect(readTaskFormDraft(scope)).toBeNull();
  });
});

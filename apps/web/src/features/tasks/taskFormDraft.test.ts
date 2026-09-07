import { beforeEach, describe, expect, it } from 'vitest';
import { clearTaskFormDraft, readTaskFormDraft, saveTaskFormDraft, TASK_FORM_DRAFT_KEY } from './taskFormDraft';

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
  subtasks: [{ title: '水筒', required: true }, { title: 'タオル', required: false }],
};

describe('task form draft', () => {
  beforeEach(() => sessionStorage.clear());

  it('restores a create draft after the form is closed', () => {
    saveTaskFormDraft(draft);
    expect(readTaskFormDraft()).toEqual(draft);
  });

  it('clears only when explicitly requested after successful save', () => {
    saveTaskFormDraft(draft);
    clearTaskFormDraft();
    expect(sessionStorage.getItem(TASK_FORM_DRAFT_KEY)).toBeNull();
    expect(readTaskFormDraft()).toBeNull();
  });

  it('fails closed for corrupt device state', () => {
    sessionStorage.setItem(TASK_FORM_DRAFT_KEY, '{broken');
    expect(readTaskFormDraft()).toBeNull();
  });
});

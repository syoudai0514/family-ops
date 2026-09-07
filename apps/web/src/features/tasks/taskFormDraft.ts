import type { CompletionMode, RoutinePhase } from '../../lib/types';

export type TaskFormDraft = {
  title: string;
  category: string;
  scheduledDate: string;
  dueLocalTime: string;
  calendarEndLocalTime: string;
  calendarVisibility: 'hidden' | 'special';
  assigneeId: string;
  completionMode: CompletionMode;
  routinePhase: RoutinePhase | '';
  subtasks: Array<{ title: string; required: boolean }>;
};

export const TASK_FORM_DRAFT_KEY = 'family-ops:task-form-draft:v1';

export function readTaskFormDraft(): TaskFormDraft | null {
  try {
    const raw = sessionStorage.getItem(TASK_FORM_DRAFT_KEY);
    if (!raw) return null;
    const value = JSON.parse(raw) as Partial<TaskFormDraft>;
    if (typeof value.title !== 'string' || typeof value.scheduledDate !== 'string') return null;
    return {
      title: value.title,
      category: typeof value.category === 'string' ? value.category : 'other',
      scheduledDate: value.scheduledDate,
      dueLocalTime: typeof value.dueLocalTime === 'string' ? value.dueLocalTime : '',
      calendarEndLocalTime: typeof value.calendarEndLocalTime === 'string' ? value.calendarEndLocalTime : '',
      calendarVisibility: value.calendarVisibility === 'special' ? 'special' : 'hidden',
      assigneeId: typeof value.assigneeId === 'string' ? value.assigneeId : '',
      completionMode: value.completionMode === 'subtasks' ? 'subtasks' : 'whole',
      routinePhase: value.routinePhase === 'morning' || value.routinePhase === 'evening' || value.routinePhase === 'anytime' ? value.routinePhase : '',
      subtasks: Array.isArray(value.subtasks)
        ? value.subtasks.filter((item): item is { title: string; required: boolean } => Boolean(item) && typeof item.title === 'string' && typeof item.required === 'boolean')
        : [{ title: '', required: true }],
    };
  } catch {
    return null;
  }
}

export function saveTaskFormDraft(draft: TaskFormDraft): void {
  try { sessionStorage.setItem(TASK_FORM_DRAFT_KEY, JSON.stringify(draft)); } catch { /* unavailable */ }
}

export function clearTaskFormDraft(): void {
  try { sessionStorage.removeItem(TASK_FORM_DRAFT_KEY); } catch { /* unavailable */ }
}

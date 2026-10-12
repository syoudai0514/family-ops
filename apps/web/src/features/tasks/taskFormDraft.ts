import type { CompletionMode, RoutinePhase } from '../../lib/types';
import type { ScheduleDetails } from '../planning/scheduleDetails';

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
  schedulerDetails?: ScheduleDetails;
};

export type TaskFormDraftScope = { userId: string; householdId: string };

export const TASK_FORM_DRAFT_KEY = 'family-ops:task-form-draft:v2';

function draftKey(scope: TaskFormDraftScope): string {
  return `${TASK_FORM_DRAFT_KEY}:${encodeURIComponent(scope.userId)}:${encodeURIComponent(scope.householdId)}`;
}

export function readTaskFormDraft(scope: TaskFormDraftScope | null): TaskFormDraft | null {
  if (!scope) return null;
  try {
    // Unscoped v1 drafts have no trustworthy owner and must never be restored
    // into another account or household on a shared device.
    const raw = sessionStorage.getItem(draftKey(scope));
    if (!raw) return null;
    const value = JSON.parse(raw) as Partial<TaskFormDraft>;
    if (typeof value.title !== 'string' || typeof value.scheduledDate !== 'string') return null;
    return {
      title: value.title,
      category: typeof value.category === 'string' ? value.category : 'other',
      scheduledDate: value.scheduledDate,
      dueLocalTime: typeof value.dueLocalTime === 'string' ? value.dueLocalTime : '',
      calendarEndLocalTime:
        typeof value.calendarEndLocalTime === 'string' ? value.calendarEndLocalTime : '',
      calendarVisibility: value.calendarVisibility === 'special' ? 'special' : 'hidden',
      assigneeId: typeof value.assigneeId === 'string' ? value.assigneeId : '',
      completionMode: value.completionMode === 'subtasks' ? 'subtasks' : 'whole',
      routinePhase:
        value.routinePhase === 'morning' ||
        value.routinePhase === 'evening' ||
        value.routinePhase === 'anytime'
          ? value.routinePhase
          : '',
      subtasks: Array.isArray(value.subtasks)
        ? value.subtasks.filter(
            (item): item is { title: string; required: boolean } =>
              Boolean(item) && typeof item.title === 'string' && typeof item.required === 'boolean',
          )
        : [{ title: '', required: true }],
      schedulerDetails: value.schedulerDetails,
    };
  } catch {
    return null;
  }
}

export function saveTaskFormDraft(draft: TaskFormDraft, scope: TaskFormDraftScope | null): void {
  if (!scope) return;
  try {
    sessionStorage.setItem(draftKey(scope), JSON.stringify(draft));
  } catch {
    /* unavailable */
  }
}

export function clearTaskFormDraft(scope: TaskFormDraftScope | null): void {
  if (!scope) return;
  try {
    sessionStorage.removeItem(draftKey(scope));
  } catch {
    /* unavailable */
  }
}

import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import type { TaskInstance } from '../../lib/types';

/** A navigation hint only. It must never stand in for consent or a command. */
export interface AssignmentEntry {
  taskId: string;
  assigneeUserId: string;
  requestedByUserId: string;
  householdId: string;
  date: string;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function readAssignmentEntry(
  params: URLSearchParams,
  date: string,
  householdId: string | undefined,
  currentUserId: string | undefined,
  members: HouseholdMemberWithProfile[],
): AssignmentEntry | undefined {
  const keys = ['date', 'for', 'assignment_task', 'assignment_to'];
  if (keys.some((key) => params.getAll(key).length !== 1)) return undefined;
  if (!householdId || !currentUserId || params.get('date') !== date || params.get('for') !== currentUserId) return undefined;
  const taskId = params.get('assignment_task') ?? '';
  const assigneeUserId = params.get('assignment_to') ?? '';
  if (![taskId, assigneeUserId, currentUserId].every((value) => UUID.test(value))) return undefined;
  const isAdult = (userId: string) => members.some((member) =>
    member.user_id === userId && member.household_id === householdId && member.member_role === 'adult');
  if (!isAdult(currentUserId) || !isAdult(assigneeUserId)) return undefined;
  return { taskId, assigneeUserId, requestedByUserId: currentUserId, householdId, date };
}

export function matchesAssignmentEntry(task: TaskInstance, entry: AssignmentEntry | undefined): boolean {
  return Boolean(entry && task.id === entry.taskId && task.household_id === entry.householdId
    && task.scheduled_date === entry.date && ['todo', 'in_progress'].includes(task.status)
    && task.task_kind === 'transport' && ['dropoff', 'pickup'].includes(task.category));
}

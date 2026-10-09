import { isTaskOnUsersList, type RecordingTask } from './taskRecording';

export interface OwnerGroups<T> {
  /** Assigned to me, or a shared task I have taken. */
  mine: T[];
  /** 誰でもOK / nobody yet: on both lists. */
  shared: T[];
  /** The other adult's: shown apart, never next to mine, so a tap cannot land on it by mistake. */
  partner: T[];
}

/** Splits a day's tasks by whose they are, seen from `userId`. Null when the viewer is unknown. */
export function groupTasksByOwner<T extends RecordingTask>(tasks: T[], userId: string | null | undefined): OwnerGroups<T> | null {
  if (!userId) return null;
  const groups: OwnerGroups<T> = { mine: [], shared: [], partner: [] };
  for (const task of tasks) {
    if (!isTaskOnUsersList(task, userId)) groups.partner.push(task);
    else if (task.planned_assignee_id === userId || task.active_claimant_user_id === userId) groups.mine.push(task);
    else groups.shared.push(task);
  }
  return groups;
}

/** The other adult's task, from the viewer's side (their assignee, or a shared task they took). */
export function isPartnersTask(task: RecordingTask, userId: string | null | undefined): boolean {
  return Boolean(userId) && !isTaskOnUsersList(task, userId as string);
}

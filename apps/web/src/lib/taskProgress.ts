/** The per-parent limit keeps one current note per task, including tasks without notes. */
export const TASK_PROGRESS_SELECT = 'latest_work_progress:task_events!task_events_household_id_task_instance_id_fkey(id,actor_id,created_at,payload)';

export interface TaskWorkProgressRecord {
  id: string;
  actor_id: string | null;
  created_at: string;
  payload: Record<string, unknown>;
}

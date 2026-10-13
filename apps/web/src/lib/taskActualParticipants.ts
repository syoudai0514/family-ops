import { supabase } from './supabaseClient';
import type { TaskInstance } from './types';
import { withTimeout } from './withTimeout';

type ParticipantRow = {
  household_id: string;
  task_instance_id: string;
  actor_ref_id: string;
  removed_at: string | null;
  test_context_id: string | null;
};

type ActorRow = {
  id: string;
  household_id: string;
  actor_kind: string;
  real_user_id: string | null;
  test_context_id: string | null;
};

function batches(ids: string[]): string[][] {
  const result: string[][] = [];
  for (let start = 0; start < ids.length; start += 100) result.push(ids.slice(start, start + 100));
  return result;
}

/** Canonical contributors also cover checklist completion without any checked optional item. */
export async function withTaskActualParticipants<T extends TaskInstance>(
  householdId: string,
  tasks: T[],
): Promise<Array<T & { actual_participant_user_ids: string[] }>> {
  const taskIds = [...new Set(tasks
    .filter(task => task.household_id === householdId && task.status === 'completed')
    .map(task => task.id))];
  const userIdsByTask = new Map<string, Set<string>>();
  if (taskIds.length > 0) {
    const validTaskIds = new Set(taskIds);
    const participants = await Promise.all(batches(taskIds).map(ids => withTimeout(
      supabase.from('task_actual_participants')
        .select('household_id,task_instance_id,actor_ref_id,removed_at,test_context_id')
        .eq('household_id', householdId).in('task_instance_id', ids)
        .is('removed_at', null).is('test_context_id', null),
      12_000,
      '実施者の記録を読み込めませんでした。',
    )));
    for (const result of participants) if (result.error) throw result.error;
    const rows = (participants.flatMap(result => result.data ?? []) as ParticipantRow[]).filter(row =>
      row.household_id === householdId && validTaskIds.has(row.task_instance_id)
      && row.removed_at === null && row.test_context_id === null && typeof row.actor_ref_id === 'string'
    );
    const refIds = [...new Set(rows.map(row => row.actor_ref_id))];
    if (refIds.length > 0) {
      const actors = await Promise.all(batches(refIds).map(ids => withTimeout(
        supabase.from('domain_actor_refs')
          .select('id,household_id,actor_kind,real_user_id,test_context_id')
          .eq('household_id', householdId).eq('actor_kind', 'real_user')
          .is('test_context_id', null).in('id', ids),
        12_000,
        '実施者の記録を読み込めませんでした。',
      )));
      for (const result of actors) if (result.error) throw result.error;
      const validRefIds = new Set(refIds);
      const userByRef = new Map<string, string>();
      for (const actor of actors.flatMap(result => result.data ?? []) as ActorRow[]) {
        if (actor.household_id === householdId && validRefIds.has(actor.id)
          && actor.actor_kind === 'real_user' && actor.test_context_id === null
          && typeof actor.real_user_id === 'string' && actor.real_user_id) {
          userByRef.set(actor.id, actor.real_user_id);
        }
      }
      for (const row of rows) {
        const userId = userByRef.get(row.actor_ref_id);
        if (!userId) continue;
        const ids = userIdsByTask.get(row.task_instance_id) ?? new Set<string>();
        ids.add(userId);
        userIdsByTask.set(row.task_instance_id, ids);
      }
    }
  }
  return tasks.map(task => ({
    ...task,
    actual_participant_user_ids: task.household_id === householdId
      ? [...(userIdsByTask.get(task.id) ?? [])] : [],
  }));
}

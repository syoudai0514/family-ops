import { supabase } from './supabaseClient';
import { withTimeout } from './withTimeout';

/**
 * task_instances only stores the taker of a 誰でもOK task as an actor ref; the app compares
 * users. Adds active_claimant_user_id from domain_actor_refs (never select it from the table:
 * the column does not exist there).
 */
export async function withClaimantUsers<T extends { active_claimant_actor_ref_id?: string | null }>(
  householdId: string,
  rows: T[],
): Promise<Array<T & { active_claimant_user_id: string | null }>> {
  const refIds = [...new Set(rows.map((row) => row.active_claimant_actor_ref_id).filter((id): id is string => Boolean(id)))];
  const userByRef = new Map<string, string>();
  if (refIds.length > 0) {
    const { data, error } = await withTimeout(
      supabase.from('domain_actor_refs').select('id,real_user_id').eq('household_id', householdId).in('id', refIds),
      12_000,
      '担当状況の読み込みに時間がかかっています。',
    );
    if (error) throw error;
    for (const row of (data ?? []) as Array<{ id: string; real_user_id: string | null }>) {
      if (row.real_user_id) userByRef.set(row.id, row.real_user_id);
    }
  }
  return rows.map((row) => ({
    ...row,
    active_claimant_user_id: row.active_claimant_actor_ref_id ? userByRef.get(row.active_claimant_actor_ref_id) ?? null : null,
  }));
}

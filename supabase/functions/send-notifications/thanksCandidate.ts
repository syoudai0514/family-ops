import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

export type ThanksCandidate = { kind: 'task' | 'request'; id: string; title: string; recipient_id: string; name: string };

export async function loadThanksCandidate(client: SupabaseClient, actorId: string, householdId: string, now = new Date()): Promise<ThanksCandidate | null> {
  try {
    const yesterday = new Date(now.getTime() + 9 * 3600_000 - 86400_000).toISOString().slice(0, 10);
    const { data, error } = await client.rpc('server_read_thanks_candidates', { p_actor_id: actorId, p_local_date: yesterday });
    const first = Array.isArray(data) ? data[0] : null;
    if (error || !first || !['task', 'request'].includes(first.kind) || typeof first.id !== 'string' ||
        typeof first.title !== 'string' || typeof first.recipient_id !== 'string') return null;
    const member = await client.from('household_members').select('family_role').eq('household_id', householdId)
      .eq('user_id', first.recipient_id).maybeSingle();
    if (member.error || !member.data) return null;
    const name = member.data.family_role === 'mama' ? 'ママ' : member.data.family_role === 'papa' ? 'パパ' : '家族';
    return { ...first, name } as ThanksCandidate;
  } catch {
    return null;
  }
}

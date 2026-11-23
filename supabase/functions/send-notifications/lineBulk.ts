import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

type BriefItem = { type?: string; title?: string; body?: string; user_notification_id?: string };
export type LineBulk = { id: string; phase: 'morning' | 'evening' };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;

/** Bind the action to the actual notification and its stored task revisions. */
export async function loadLineBulk(client: SupabaseClient, actorId: string,
  payload: { items?: BriefItem[] } | null): Promise<LineBulk | null> {
  const briefs = (payload?.items ?? []).filter((item) => item.type === 'daily_brief.v2' &&
    (item.title === '朝のおうちノート' || item.title === '夜のおうちノート'));
  // A preceding long bundled item could hide this note under LINE's message
  // limit. Only offer "all" when the source note is the first visible block.
  if (briefs.length !== 1 || payload?.items?.[0] !== briefs[0] || !UUID.test(briefs[0].user_notification_id ?? '') ||
    typeof briefs[0].body !== 'string' || Array.from(briefs[0].body).length >= 5000) return null;
  try {
    const { data, error } = await client.rpc('server_tx_prepare_line_bulk_v1', {
      p_actor_id: actorId, p_notification_id: briefs[0].user_notification_id,
    });
    const expected = briefs[0].title === '朝のおうちノート' ? 'morning' : 'evening';
    if (error || !data || typeof data.id !== 'string' || !UUID.test(data.id) || data.phase !== expected ||
      !['ready', 'completed', 'undone'].includes(data.status)) return null;
    return { id: data.id, phase: expected };
  } catch { return null; }
}

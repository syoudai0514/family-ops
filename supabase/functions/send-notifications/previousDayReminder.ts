import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

type BriefItem = { type?: string; title?: string; user_notification_id?: string };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;

/** Use a server snapshot so a one-tap reply cannot record tentative or new work. */
export async function loadPreviousDayReminder(client: SupabaseClient, recipientId: string,
  payload: { items?: BriefItem[] } | null, now = new Date()): Promise<{ date: string; id: string; text: string } | null> {
  const items = payload?.items ?? [];
  const item = items[0];
  if (!item || item.type !== 'daily_brief.v2' || item.title !== '朝のおうちノート' ||
    !UUID.test(item.user_notification_id ?? '') || items.filter((x) => x.type === 'daily_brief.v2').length !== 1) return null;
  try {
    const { data, error } = await client.rpc('server_tx_prepare_previous_day_consent_v1', {
      p_actor_id: recipientId, p_notification_id: item.user_notification_id,
    });
    const yesterday = new Date(now.getTime() + 9 * 3600_000);
    yesterday.setUTCDate(yesterday.getUTCDate() - 1);
    if (error || !data || typeof data.id !== 'string' || !UUID.test(data.id) ||
      data.date !== yesterday.toISOString().slice(0, 10) || !['ready', 'completed', 'undone'].includes(data.status)) return null;
    return { id: data.id, date: data.date, text: '昨日の自分の分、記録しますか？（任意・コドモン送信を除く）' };
  } catch { return null; }
}

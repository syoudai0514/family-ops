import { useEffect, useState } from 'react';
import { supabase } from '../../lib/supabaseClient';

type ThanksReceipt = { id: string; created_at: string };

export function ThanksHistory({ householdId, userId, start, end }: { householdId: string; userId: string; start: string; end: string }) {
  const [rows, setRows] = useState<ThanksReceipt[]>([]);
  useEffect(() => {
    let active = true;
    const nextDay = new Date(`${end}T00:00:00Z`);
    if (Number.isNaN(nextDay.getTime())) return;
    nextDay.setUTCDate(nextDay.getUTCDate() + 1);
    void supabase.from('user_notifications').select('id,created_at')
      .eq('household_id', householdId).eq('recipient_user_id', userId).eq('type', 'thanks')
      .gte('created_at', `${start}T00:00:00+09:00`)
      .lt('created_at', `${nextDay.toISOString().slice(0, 10)}T00:00:00+09:00`)
      .order('created_at', { ascending: false })
      .then(({ data, error }) => { if (active) setRows(error ? [] : data ?? []); }, () => { if (active) setRows([]); });
    return () => { active = false; };
  }, [householdId, userId, start, end]);
  if (!rows.length) return null;
  return <ul className="history-list" aria-label="届いたありがとう">
    {rows.map((row) => <li key={row.id} className="card compact-section">
      ありがとうが届いた
      <small className="task-item-meta"> {new Intl.DateTimeFormat('ja-JP', {
        timeZone: 'Asia/Tokyo', month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit',
      }).format(new Date(row.created_at))}</small>
    </li>)}
  </ul>;
}

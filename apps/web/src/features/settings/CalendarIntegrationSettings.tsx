import { useCallback, useEffect, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';

type Connection = { id: string; external_calendar_id: string; display_name: string | null; active: boolean; reauth_required: boolean; is_family_write_target: boolean };
export function CalendarIntegrationSettings() {
  const { household } = useHousehold(); const [rows,setRows]=useState<Connection[]>([]); const [error,setError]=useState<string|null>(null);
  const load=useCallback(async()=>{ if(!household) return; const {data,error}=await supabase.from('calendar_connections').select('id,external_calendar_id,display_name,active,reauth_required,is_family_write_target').eq('household_id',household.id).eq('provider','google'); if(error) setError(error.message); else setRows(data??[]); },[household]);
  useEffect(()=>{load();},[load]);
  return <section className="card"><h2>Google Calendar</h2><p className="empty-hint">個人予定は読み取り・重複確認に使います。送迎と特別対応は、ここで選んだ家族カレンダーだけへ書き込みます。</p><p className="empty-hint">読み取り対象から、Family Ops予定の書込み先を一つ選べます。変更時は旧カレンダーのFamily Opsミラーを削除してから新しいカレンダーへ再同期します。</p>
    {rows.length===0?<p>未接続です。</p>:<ul className="task-list">{rows.map(row=><li key={row.id}><label><input type="radio" name="family-calendar" checked={row.is_family_write_target} disabled={!row.active||row.reauth_required} onChange={async()=>{setError(null);try{await callEdgeFunction(EDGE_FUNCTIONS.setFamilyCalendarTarget,{operation_id:newOperationId(),calendar_connection_id:row.id}); await load();}catch(e){setError(e instanceof Error?e.message:'書込み先を変更できませんでした。');}}} />{row.display_name??row.external_calendar_id} {row.reauth_required?'（再認証が必要）':row.active?'（接続中・読み取り対象）':'（停止中）'}</label></li>)}</ul>}
    {error&&<p role="alert" className="error-text">{error}</p>}</section>;
}

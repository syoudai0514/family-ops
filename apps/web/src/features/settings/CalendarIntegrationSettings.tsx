import { useCallback, useEffect, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';

type Connection = { id: string; external_calendar_id: string; display_name: string | null; active: boolean; reauth_required: boolean; is_family_write_target: boolean };
function oauthCallbackNotice(targetSelected: boolean) {
  const params = new URLSearchParams(window.location.search);
  if (params.get('google_calendar_connected') === '1') {
    return targetSelected
      ? 'Google Calendarの接続を更新しました。現在の家族カレンダーを継続して使います。'
      : 'Google Calendarを接続しました。家族予定を書き込むカレンダーを選んでください。';
  }
  if (params.get('google_calendar_error')) return 'Google Calendarの接続を完了できませんでした。もう一度お試しください。';
  return null;
}

export function CalendarIntegrationSettings({ returnTo = '/settings' }: { returnTo?: string }) {
  const { household } = useHousehold(); const [rows,setRows]=useState<Connection[]>([]); const [error,setError]=useState<string|null>(null); const [connecting,setConnecting]=useState(false);
  const load=useCallback(async()=>{ if(!household) return; const {data,error}=await supabase.from('calendar_connections').select('id,external_calendar_id,display_name,active,reauth_required,is_family_write_target').eq('household_id',household.id).eq('provider','google'); if(error) setError(error.message); else setRows(data??[]); },[household]);
  useEffect(()=>{load();},[load]);
  const startOAuth=async()=>{setConnecting(true);setError(null);try{const result=await callEdgeFunction<{authorization_url:string}>(EDGE_FUNCTIONS.googleCalendarOauthStart,{return_to:returnTo});window.location.assign(result.authorization_url);}catch(e){setError(e instanceof Error?e.message:'Google Calendarを開けませんでした。');setConnecting(false);}};
  const canSelect=rows.some((row)=>row.active&&!row.reauth_required);
  const targetSelected=rows.some((row)=>row.is_family_write_target&&row.active&&!row.reauth_required);
  // An inactive historical calendar is a permission/candidate loss, not a
  // broken household credential. Only an active connection that explicitly
  // requires reauth should change the primary action to reconnect.
  const reauthNeeded=rows.some((row)=>row.active&&row.reauth_required);
  const callbackNotice=oauthCallbackNotice(targetSelected);
  return <section className="card"><h2>Google Calendar</h2><p className="empty-hint">個人予定は読み取り・重複確認に使います。送迎と特別対応は、ここで選んだ家族カレンダーだけへ書き込みます。</p><p className="empty-hint">読み取り対象から、Family Ops予定の書込み先を一つ選べます。変更時は旧カレンダーのFamily Opsミラーを削除してから新しいカレンダーへ再同期します。</p>
    {callbackNotice&&<p role="status">{callbackNotice}</p>}
    {rows.length===0?<p>Google Calendar: 未接続です。</p>:<><p role="status">Google Calendar ✓ 接続済み</p>{canSelect&&!targetSelected&&<p role="status">家族予定を書き込むカレンダーを選んでください</p>}<ul className="task-list">{rows.map(row=><li key={row.id}><label><input type="radio" name="family-calendar" checked={row.is_family_write_target} disabled={!row.active||row.reauth_required} onChange={async()=>{setError(null);try{await callEdgeFunction(EDGE_FUNCTIONS.setFamilyCalendarTarget,{operation_id:newOperationId(),calendar_connection_id:row.id}); await load();}catch(e){setError(e instanceof Error?e.message:'書込み先を変更できませんでした。');}}} />{row.display_name??row.external_calendar_id} {!row.active?'（停止中）':row.reauth_required?'（再認証が必要）':'（接続中・読み取り対象）'}</label></li>)}</ul></>}
    <button type="button" onClick={()=>void startOAuth()} disabled={connecting}>{connecting?'接続中…':reauthNeeded?'Google Calendarを再接続':'Google Calendarを接続'}</button>
    {error&&<p role="alert" className="error-text">{error}</p>}</section>;
}

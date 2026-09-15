import { useCallback, useEffect, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { useCalendarFreshness } from '../planning/useCalendarFreshness';

type Connection = { id: string; external_calendar_id: string; display_name: string | null; active: boolean; reauth_required: boolean; is_family_write_target: boolean };
// The radio picks which calendar おうちノート WRITES family events to, but every
// row used to render the same '（接続中・読み取り対象）' suffix regardless of
// `is_family_write_target`. The selected row therefore also said "読み取り対象",
// leaving the control's entire purpose invisible: two identical labels and a
// radio with no stated consequence.
export function calendarRowLabel(row: Pick<Connection, 'active' | 'reauth_required' | 'is_family_write_target'>): string {
  if (!row.active) return '（停止中）';
  if (row.reauth_required) return '（再認証が必要）';
  if (row.is_family_write_target) return '（家族カレンダー・ここに書き込みます）';
  return '（読み取りのみ）';
}

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
  // The week view can report `calendar_stale` while every flag read here says
  // healthy. Offering the same re-sync action in both places means following
  // the week view's advice to "check the connection" is no longer a dead end.
  const freshness=useCalendarFreshness({enabled:Boolean(household),auto:false});
  return <section className="card"><h2>Google Calendar</h2><p className="empty-hint">個人予定は読み取り・重複確認に使います。送迎と特別対応は、ここで選んだ家族カレンダーだけへ書き込みます。</p><p className="empty-hint">読み取り対象の中から、家族の予定を書き込むカレンダーを一つ選べます。変更すると、前のカレンダーに書き込んだ予定を消してから新しいカレンダーへ入れ直します。</p>
    {callbackNotice&&<p role="status">{callbackNotice}</p>}
    {rows.length===0?<p>Google Calendar: 未接続です。</p>:<><p role="status">Google Calendar ✓ 接続済み</p>{canSelect&&!targetSelected&&<p role="status">家族予定を書き込むカレンダーを選んでください</p>}<ul className="task-list">{rows.map(row=><li key={row.id}><label><input type="radio" name="family-calendar" checked={row.is_family_write_target} disabled={!row.active||row.reauth_required} onChange={async()=>{setError(null);try{await callEdgeFunction(EDGE_FUNCTIONS.setFamilyCalendarTarget,{operation_id:newOperationId(),calendar_connection_id:row.id}); await load();}catch(e){setError(e instanceof Error?e.message:'書込み先を変更できませんでした。');}}} />{row.display_name??row.external_calendar_id} {calendarRowLabel(row)}</label></li>)}</ul></>}
    {rows.length>0&&<div className="calendar-sync-row">
      <button type="button" className="secondary-button" disabled={freshness.syncing} onClick={()=>void freshness.resync()}>{freshness.syncing?'同期中…':'予定を今すぐ同期する'}</button>
      {freshness.requestedAt&&<p role="status" className="empty-hint">同期を開始しました。反映まで少し時間がかかることがあります。</p>}
      {freshness.error&&<p role="alert" className="error-text">{freshness.error}</p>}
    </div>}
    <button type="button" onClick={()=>void startOAuth()} disabled={connecting}>{connecting?'接続中…':reauthNeeded?'Google Calendarを再接続':'Google Calendarを接続'}</button>
    {error&&<p role="alert" className="error-text">{error}</p>}</section>;
}

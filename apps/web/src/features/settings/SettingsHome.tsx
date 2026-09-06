import { useState } from 'react';
import { Link } from 'react-router-dom';
import { InviteSection } from '../household/InviteSection';
import { supabase } from '../../lib/supabaseClient';
import { CalendarIntegrationSettings } from './CalendarIntegrationSettings';
import { useHousehold } from '../../app/HouseholdContext';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';

export function SettingsHome() {
  const { members, refresh } = useHousehold();
  const [signingOut, setSigningOut] = useState(false);

  async function handleSignOut() {
    setSigningOut(true);
    try {
      await supabase.auth.signOut();
    } finally {
      setSigningOut(false);
    }
  }

  return (
    <main className="app-shell settings-home">
      <h1>設定</h1>
      <p className="page-lead">いつもの担当や通知を、家族のルールとして整えます。</p>
      <section className="settings-list" aria-label="設定メニュー">
        <Link to="/settings/routines" className="settings-link"><strong>いつもの担当</strong><span>送り・お迎え、夜の家事、朝の準備</span></Link>
        <Link to="/settings/categories" className="settings-link"><strong>カテゴリ</strong><span>予定追加で選ぶ項目と色</span></Link>
        <Link to="/settings/terminology" className="settings-link"><strong>家庭内用語</strong><span>LINEで使う言い回しと意味</span></Link>
        <Link to="/notifications" className="settings-link"><strong>通知</strong><span>LINEとアプリ内のお知らせ</span></Link>
        <Link to="/handovers" className="settings-link"><strong>引き継ぎ</strong><span>朝・夜の共有メモ</span></Link>
        <Link to="/planning/google-review" className="settings-link"><strong>Google予定の変更確認</strong><span>時間変更・削除・重複候補を確認</span></Link>
        <Link to="/settings/test-simulation" className="settings-link"><strong>🧪 1人テストモード</strong><span>1アカウントでお願い→返事→完了まで安全に試す</span></Link>
      </section>
      <CalendarIntegrationSettings />
      <section className="card settings-invite"><h2>家族</h2><p className="empty-hint">P/M表示と担当色は家庭で固定します。</p>{members.map(member=><label key={member.user_id}>{member.profile?.display_name??member.user_id}<select value={member.family_role??''} onChange={async e=>{if(e.target.value) {await callEdgeFunction(EDGE_FUNCTIONS.setFamilyRole,{operation_id:newOperationId(),user_id:member.user_id,family_role:e.target.value});await refresh();}}}><option value="">未設定</option><option value="papa">パパ（P・緑）</option><option value="mama">ママ（M・橙）</option></select></label>)}<InviteSection /></section>
      <section className="card settings-account">
        <h2>アカウント</h2>
        <p className="empty-hint">この端末でのログインを終了します。</p>
        <button type="button" className="text-button" onClick={handleSignOut} disabled={signingOut}>
          {signingOut ? 'サインアウト中…' : 'サインアウト'}
        </button>
      </section>
      <button type="button" className="text-button" onClick={() => window.location.assign('/today')}>今日へ戻る</button>
    </main>
  );
}

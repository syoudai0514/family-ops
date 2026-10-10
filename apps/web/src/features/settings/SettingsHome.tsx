import { useState } from 'react';
import { Link } from 'react-router-dom';
import { InviteSection } from '../household/InviteSection';
import { supabase } from '../../lib/supabaseClient';
import { CalendarIntegrationSettings } from './CalendarIntegrationSettings';
import { FamilyRoles } from './FamilyRoles';

export function SettingsHome() {
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
        <Link to="/settings/routines" className="settings-link"><strong>いつもの担当</strong><span>送り・お迎え、家事、朝の準備</span></Link>
        <Link to="/notifications" className="settings-link"><strong>通知・LINE連携</strong><span>連携状態と、お知らせの頻度</span></Link>
        <Link to="/settings/children" className="settings-link"><strong>子ども・園・学校</strong><span>おたよりの対象とクラス</span></Link>
      </section>
      <details className="card"><summary>入力を自分たちに合わせる</summary><div className="settings-list">
        <Link to="/settings/categories" className="settings-link">カテゴリと色</Link>
        <Link to="/settings/terminology" className="settings-link">家庭内の言い回し</Link>
      </div></details>
      <details className="card"><summary>使い方・困ったとき</summary><div className="settings-list">
        <Link to="/settings/line-reference" className="settings-link">LINEとアプリの使い方</Link>
        <Link to="/settings/outcome-semantics" className="settings-link">削除・中止・結果の違い</Link>
        <Link to="/planning/google-review" className="settings-link">Google予定の変更確認</Link>
      </div></details>
      <details className="card"><summary>安全に使い方を試す</summary><Link to="/settings/test-simulation">1人テストモード</Link></details>
      <CalendarIntegrationSettings />
      <section className="card settings-invite"><h2>家族</h2><FamilyRoles /><InviteSection /></section>
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

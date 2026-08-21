import { useState } from 'react';
import { Link } from 'react-router-dom';
import { InviteSection } from '../household/InviteSection';
import { supabase } from '../../lib/supabaseClient';

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
        <Link to="/settings/routines" className="settings-link"><strong>いつもの担当</strong><span>送り・お迎え、夜の家事、朝の準備</span></Link>
        <Link to="/notifications" className="settings-link"><strong>通知</strong><span>LINEとアプリ内のお知らせ</span></Link>
        <Link to="/handovers" className="settings-link"><strong>引き継ぎ</strong><span>朝・夜の共有メモ</span></Link>
      </section>
      <section className="card settings-invite"><h2>家族</h2><InviteSection /></section>
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

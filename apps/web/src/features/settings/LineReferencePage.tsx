import { Link } from 'react-router-dom';

const LINE_ENTRY_POINTS = [
  { label: '今日', message: '今日の予定は？', to: '/today', detail: '今日の予定・要対応・残りを確認' },
  { label: '入力', message: '入力', to: '/today?entry=checkin', detail: '定例Check-inと個別結果の入力' },
  { label: '追加', message: '追加したい', to: '/concierge', detail: '予定・タスク・買い物などを自然文から追加' },
  { label: 'お願い', message: 'お願いを送りたい', to: '/requests', detail: 'お願いを作成し、返答・相談状態を確認' },
  { label: '共有', message: '共有', to: '/handovers', detail: '引き継ぎ・共有を確認' },
  { label: 'その他', message: 'その他', to: '/settings', detail: '設定や管理メニューを開く' },
] as const;

export function LineReferencePage() {
  return (
    <main className="app-shell settings-home">
      <div className="today-header">
        <div>
          <p className="eyebrow">LINE / PWA 共通</p>
          <h1>回答する場所: PWA / LINE</h1>
        </div>
        <Link to="/settings" className="text-button">設定へ戻る</Link>
      </div>

      <section className="card" aria-labelledby="line-entry-title">
        <h2 id="line-entry-title">LINEの固定入口 6つ</h2>
        <p className="page-lead">LINEでは下の短い言葉をそのまま送れます。PWAから操作しても、保存先は同じcanonicalデータです。</p>
        <ul className="settings-list line-reference-list">
          {LINE_ENTRY_POINTS.map((entry) => (
            <li key={entry.label}>
              <Link to={entry.to} className="settings-link">
                <strong>{entry.label}</strong>
                <span>LINE: 「{entry.message}」 / PWA: {entry.detail}</span>
              </Link>
            </li>
          ))}
        </ul>
      </section>

      <section className="card" aria-labelledby="line-result-title">
        <h2 id="line-result-title">個別結果はどちらから答えても同じ</h2>
        <p>完了・相手が対応・できなかった・今回は不要・中止・再予定・不明は、PWAのCheck-inとLINEで同じ7種類として記録します。</p>
        <p className="empty-hint">LINE用とPWA用に別の実績コピーは作りません。どちらで答えてもcanonical Task / Historyへ反映されます。</p>
        <div className="task-item-actions">
          <Link to="/today?entry=checkin" className="secondary-button">PWAで入力する</Link>
          <Link to="/history" className="text-button">履歴で結果を確認</Link>
        </div>
      </section>
    </main>
  );
}

export { LINE_ENTRY_POINTS };

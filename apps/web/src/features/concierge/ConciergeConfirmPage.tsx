import { useLocation, useNavigate } from 'react-router-dom';
import type { ConciergeRouteState } from './conciergeFlow';
import './concierge.css';

export function ConciergeConfirmPage() {
  const navigate = useNavigate();
  const state = (useLocation().state ?? {}) as ConciergeRouteState;
  return <div className="app-shell concierge-page">
    <button type="button" className="text-button concierge-back" onClick={() => navigate(-1)}>‹ 戻る</button>
    <div className="eyebrow">最終確認</div><h1>登録前の確認</h1>
    <section className="card"><b>{state.candidates?.length ?? 0}件を選択中</b><p className="page-lead">この画面に入るまではbusiness objectを作成していません。登録処理は候補種別ごとの既存canonical commandへ接続します。</p></section>
    <p className="notice">実装中の安全柵：canonical command接続が完了するまでは登録ボタンを出しません。候補確認だけで保存されることはありません。</p>
  </div>;
}

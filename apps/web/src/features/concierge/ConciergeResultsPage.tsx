import { useMemo, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { readOnlyDestination, type ConciergeCandidate, type ConciergeRouteState } from './conciergeFlow';
import './concierge.css';

const KIND_LABEL: Record<ConciergeCandidate['kind'], string> = {
  task: 'ToDo', request: 'お願い', shopping: '買い物', share: '共有・引き継ぎ', actual: '実績',
};

export function ConciergeResultsPage() {
  const navigate = useNavigate();
  const location = useLocation();
  const state = (location.state ?? {}) as ConciergeRouteState;
  const candidates = state.candidates ?? [];
  const [selected, setSelected] = useState(() => new Set(candidates.map((candidate) => candidate.candidateId)));
  const actualOnly = Boolean(state.actualOnly);
  const visibleCandidates = useMemo(() => actualOnly ? candidates.filter((candidate) => candidate.kind === 'actual') : candidates, [actualOnly, candidates]);
  const ambiguous = visibleCandidates.filter((candidate) => candidate.missingFields.length > 0);

  if (state.readOnlyIntent) {
    return <div className="app-shell concierge-page">
      <button type="button" className="text-button concierge-back" onClick={() => navigate(-1)}>‹ 戻る</button>
      <div className="eyebrow">確認</div><h1>登録する内容はありません</h1>
      <section className="card"><b>これは照会として扱います</b><p className="page-lead">「{state.draft}」から業務オブジェクトは作りません。</p><button type="button" onClick={() => navigate(readOnlyDestination(state.readOnlyIntent!))}>内容を見る</button></section>
    </div>;
  }

  return <div className="app-shell concierge-page">
    <button type="button" className="text-button concierge-back" onClick={() => navigate(-1)}>‹ 戻る</button>
    <div className="eyebrow">候補を確認</div><h1>まとめて確認</h1>
    <p className="page-lead">理解できた内容はまとめて表示します。不要な候補は外せます。</p>
    {visibleCandidates.map((candidate) => <label key={candidate.candidateId} className="card concierge-candidate">
      <input type="checkbox" checked={selected.has(candidate.candidateId)} onChange={() => setSelected((current) => { const next = new Set(current); if (next.has(candidate.candidateId)) next.delete(candidate.candidateId); else next.add(candidate.candidateId); return next; })} />
      <span><span className="badge">{KIND_LABEL[candidate.kind]}</span><b>{candidate.title}</b><small>{candidate.sourceText}</small>{candidate.intent?.scheduledDate && <small>対象日：{candidate.intent.scheduledDate}</small>}{candidate.intent?.targetRole && <small>担当：{candidate.intent.targetRole === 'papa' ? 'パパ' : 'ママ'}</small>}</span>
    </label>)}
    {state.clarification && <section className="card"><b>ここだけ確認</b><p>{state.clarification}</p></section>}
    {ambiguous.length > 0 && <section className="card"><b>ここだけ確認</b>{ambiguous.map((candidate) => <p key={candidate.candidateId}>{candidate.title}：{candidate.missingFields.join(' / ')} が未確定です。</p>)}</section>}
    {visibleCandidates.length === 0 && <p className="empty-hint">登録候補を作れませんでした。戻って言い方を少し変えてください。</p>}
    <button type="button" className="concierge-wide" disabled={selected.size === 0 || ambiguous.some((candidate) => selected.has(candidate.candidateId))} onClick={() => navigate('/concierge/confirm', { state: { ...state, candidates: visibleCandidates.filter((candidate) => selected.has(candidate.candidateId)) } })}>選択した内容をまとめて登録</button>
    <p className="meta">曖昧な部分だけ確認します。家庭内の言葉の意味を覚えても、担当ルールは勝手に変更しません。</p>
  </div>;
}

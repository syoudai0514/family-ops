import { useMemo, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useHousehold } from '../../app/HouseholdContext';
import { clearConciergeDraft, type ConciergeCandidate, type ConciergeRouteState } from './conciergeFlow';
import { commitConciergeCandidates, type ConciergeCommitResult } from './conciergeCommit';
import './concierge.css';

const KIND_LABEL = { task: 'ToDo', request: 'お願い', shopping: '買い物', share: '共有・引き継ぎ', actual: '実績' } as const;
export type DuplicateDecision = 'existing' | 'update' | 'separate';

export function needsDuplicateDecision(candidate: ConciergeCandidate): boolean {
  const text = `${candidate.sourceText} ${candidate.title}`;
  return /(?:同じ|重複|既存|すでに|もうある|似た)/.test(text);
}

export function ConciergeConfirmPage() {
  const navigate = useNavigate();
  const location = useLocation();
  const state = (location.state ?? {}) as ConciergeRouteState;
  const { members, me, partner, household } = useHousehold();
  const candidates = state.candidates ?? [];
  const unresolved = useMemo(() => candidates.filter((candidate) => candidate.missingFields.length > 0), [candidates]);
  const duplicateCandidates = useMemo(() => candidates.filter(needsDuplicateDecision), [candidates]);
  const [duplicateDecisions, setDuplicateDecisions] = useState<Record<string, DuplicateDecision>>({});
  const [busy, setBusy] = useState(false);
  const [results, setResults] = useState<ConciergeCommitResult[] | null>(null);
  const duplicateUnresolved = duplicateCandidates.some((candidate) => !duplicateDecisions[candidate.candidateId]);

  async function register() {
    if (busy || unresolved.length > 0 || duplicateUnresolved || candidates.length === 0) return;
    setBusy(true);
    const commitCandidates = candidates.filter((candidate) => duplicateDecisions[candidate.candidateId] !== 'existing');
    const existingResults: ConciergeCommitResult[] = candidates
      .filter((candidate) => duplicateDecisions[candidate.candidateId] === 'existing')
      .map((candidate) => ({ candidateId: candidate.candidateId, kind: candidate.kind, title: candidate.title, ok: true, message: '既存を使うため新規登録しません' }));
    const committed = await commitConciergeCandidates(commitCandidates, {
      members, me, partner, timeZone: household?.timezone ?? 'Asia/Tokyo',
    });
    const next = [...existingResults, ...committed];
    setResults(next);
    setBusy(false);
    if (next.length === candidates.length && next.every((item) => item.ok)) clearConciergeDraft();
  }

  const allSaved = results?.length === candidates.length && results.every((item) => item.ok);

  return <div className="app-shell concierge-page">
    <button type="button" className="text-button concierge-back" onClick={() => navigate(-1)}>‹ 戻る</button>
    <div className="eyebrow">最終確認</div><h1>この内容で登録</h1>
    <p className="page-lead">この画面で登録を押すまで、業務データは作りません。</p>
    {candidates.map((candidate) => <section key={candidate.candidateId} className="card concierge-candidate"><span className="badge">{KIND_LABEL[candidate.kind]}</span><b>{candidate.title}</b><small>{candidate.sourceText}</small>{candidate.intent?.scheduledDate && <small>対象日：{candidate.intent.scheduledDate}</small>}</section>)}
    {unresolved.length > 0 && <section className="card"><b>ここだけ確認が必要です</b>{unresolved.map((candidate) => <p key={candidate.candidateId}>{candidate.title}：{candidate.missingFields.join(' / ')}</p>)}<button type="button" className="secondary-button" onClick={() => navigate(-1)}>候補へ戻る</button></section>}
    {duplicateCandidates.length > 0 && <section className="card" aria-label="重複候補の確認">
      <b>重複かもしれない候補を確認</b>
      <p className="page-lead">既存を使う / 既存を更新する / 別物として追加する、のどれかを人が選ぶまで登録しません。</p>
      {duplicateCandidates.map((candidate) => <div key={candidate.candidateId} className="duplicate-review-row">
        <strong>{candidate.title}</strong>
        <div className="concierge-actions">
          <button type="button" className={duplicateDecisions[candidate.candidateId] === 'existing' ? '' : 'secondary-button'} onClick={() => setDuplicateDecisions((current) => ({ ...current, [candidate.candidateId]: 'existing' }))}>既存を使う</button>
          <button type="button" className={duplicateDecisions[candidate.candidateId] === 'update' ? '' : 'secondary-button'} onClick={() => setDuplicateDecisions((current) => ({ ...current, [candidate.candidateId]: 'update' }))}>既存を更新</button>
          <button type="button" className={duplicateDecisions[candidate.candidateId] === 'separate' ? '' : 'secondary-button'} onClick={() => setDuplicateDecisions((current) => ({ ...current, [candidate.candidateId]: 'separate' }))}>別物として追加</button>
        </div>
      </div>)}
      <p className="meta">「既存を更新」は現時点では同じ canonical command で人確認後に確定し、provider側の勝手な更新は行いません。</p>
    </section>}
    {results && <section className="card"><b>{allSaved ? '登録完了' : '登録結果'}</b>{results.map((item) => <p key={item.candidateId}>{item.ok ? '✓' : '!'} {item.title}：{item.message}</p>)}</section>}
    {!results && <button type="button" className="concierge-wide" disabled={busy || unresolved.length > 0 || duplicateUnresolved || candidates.length === 0} onClick={() => void register()}>{busy ? '登録中…' : '登録する'}</button>}
    {allSaved && <button type="button" className="concierge-wide" onClick={() => navigate(state.originPath ?? '/today', { replace: true, state: { restoreScrollY: state.originScrollY ?? 0 } })}>元の画面へ戻る</button>}
    {!allSaved && !results && <p className="meta">確認後の登録は既存の canonical Edge command を使います。予定外実績も作成→完了を1つのDB transactionで確定します。</p>}
  </div>;
}

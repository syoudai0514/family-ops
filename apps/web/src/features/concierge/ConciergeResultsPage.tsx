import { useMemo, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { readOnlyDestination, resolveEditedConciergeCandidate, type ConciergeCandidate, type ConciergeRouteState } from './conciergeFlow';\nimport { requestMessageIsReviewed } from './confirmedCommand';
import './concierge.css';

const KIND_LABEL: Record<ConciergeCandidate['kind'], string> = {
  task: 'ToDo', request: 'お願い', shopping: '買い物', share: '共有・引き継ぎ', actual: '実績',
};

export function ConciergeResultsPage() {
  const navigate = useNavigate();
  const location = useLocation();
  const state = (location.state ?? {}) as ConciergeRouteState;
  const initialCandidates = state.candidates ?? [];
  const actualOnly = Boolean(state.actualOnly);
  const [candidates, setCandidates] = useState<ConciergeCandidate[]>(initialCandidates);
  const [selected, setSelected] = useState(() => new Set(initialCandidates.filter((candidate) => !actualOnly || candidate.kind === 'actual').map((candidate) => candidate.candidateId)));
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editTitle, setEditTitle] = useState('');
  const [editDate, setEditDate] = useState('');\n  const [editMessage, setEditMessage] = useState('');
  const [resolvingId, setResolvingId] = useState<string | null>(null);
  const [editError, setEditError] = useState<string | null>(null);
  const visibleCandidates = useMemo(() => actualOnly ? candidates.filter((candidate) => candidate.kind === 'actual') : candidates, [actualOnly, candidates]);
  const ambiguous = visibleCandidates.filter((candidate) => candidate.missingFields.length > 0);

  async function resolveAssignee(candidateId: string, role: 'papa' | 'mama') {
    const candidate = candidates.find((row) => row.candidateId === candidateId);
    if (!candidate) return;
    const edited: ConciergeCandidate = {
      ...candidate,
      candidateRevision: (candidate.candidateRevision ?? 1) + 1,
      intent: { ...(candidate.intent ?? {}), targetRole: role },
      missingFields: candidate.missingFields.filter((field) => field !== 'assignee'),
    };
    setResolvingId(candidateId);
    setEditError(null);
    try {
      const resolved = await resolveEditedConciergeCandidate(edited);
      setCandidates((current) => current.map((row) => row.candidateId === candidateId ? resolved : row));
    } catch (error) {
      setEditError(error instanceof Error ? error.message : '変更後の内容を確認できませんでした。');
    } finally {
      setResolvingId(null);
    }
  }

  function beginEdit(candidate: ConciergeCandidate) {
    setEditingId(candidate.candidateId);
    setEditTitle(candidate.title);
    setEditDate(candidate.intent?.scheduledDate ?? '');\n    setEditMessage(candidate.intent?.sharedMessage ?? '');
  }

  async function saveEdit(candidateId: string) {
    const nextTitle = editTitle.trim();
    if (!nextTitle) return;
    const candidate = candidates.find((row) => row.candidateId === candidateId);
    if (!candidate) return;
    const nextDate = editDate || candidate.intent?.scheduledDate;
    const nextMessage = candidate.kind === 'request' ? editMessage.trim() : candidate.intent?.sharedMessage ?? null;
    const conditionChanged = candidate.title !== nextTitle || candidate.intent?.scheduledDate !== nextDate;
    const messageChanged = candidate.kind === 'request' && (candidate.intent?.sharedMessage ?? '') !== nextMessage;
    const currentRevision = candidate.candidateRevision ?? 1;
    const nextRevision = conditionChanged || messageChanged ? currentRevision + 1 : currentRevision;
    const edited: ConciergeCandidate = {
      ...candidate,
      candidateRevision: nextRevision,
      messageReviewedRevision: candidate.kind === 'request'
        ? (messageChanged && nextMessage ? nextRevision : candidate.messageReviewedRevision)
        : candidate.messageReviewedRevision,
      title: nextTitle,
      intent: candidate.intent ? {
        ...candidate.intent,
        scheduledDate: nextDate,
        sharedMessage: candidate.kind === 'request' ? nextMessage : candidate.intent.sharedMessage,
      } : candidate.intent,
    };

    setResolvingId(candidateId);
    setEditError(null);
    try {
      const resolved = await resolveEditedConciergeCandidate(edited);
      setCandidates((current) => current.map((row) => row.candidateId === candidateId ? resolved : row));
      setEditingId(null);
    } catch (error) {
      setEditError(error instanceof Error ? error.message : '変更後の内容を確認できませんでした。');
    } finally {
      setResolvingId(null);
    }
  }

  function confirmRequestMessage(candidateId: string) {
    setCandidates((current) => current.map((candidate) => candidate.candidateId !== candidateId ? candidate : {
      ...candidate,
      messageReviewedRevision: candidate.candidateRevision ?? 1,
    }));
  }

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
    <p className="page-lead">理解できた内容はまとめて表示します。不要な候補は外し、違うところだけ編集できます。</p>
    {visibleCandidates.map((candidate) => <div key={candidate.candidateId} className="card concierge-candidate">
      <label className="concierge-candidate-select">
        <input type="checkbox" checked={selected.has(candidate.candidateId)} onChange={() => setSelected((current) => { const next = new Set(current); if (next.has(candidate.candidateId)) next.delete(candidate.candidateId); else next.add(candidate.candidateId); return next; })} />
        <span><span className="badge">{KIND_LABEL[candidate.kind]}</span><b>{candidate.title}</b><small>{candidate.sourceText}</small>{candidate.intent?.scheduledDate && <small>対象日：{candidate.intent.scheduledDate}</small>}{candidate.intent?.targetRole && <small>担当：{candidate.intent.targetRole === 'papa' ? 'パパ' : 'ママ'}</small>}{candidate.intent?.context && <small>予定：{candidate.intent.context}</small>}{(candidate.intent?.subtasks?.length ?? 0) > 0 && <small>準備：{candidate.intent?.subtasks?.join(' / ')}</small>}{candidate.kind === 'request' && candidate.intent?.sharedMessage && <small>送る文面：{candidate.intent.sharedMessage}</small>}</span>
      </label>
      {editingId === candidate.candidateId ? <div className="concierge-inline-edit" aria-label={`${candidate.title}を編集`}>
        <label>内容<input value={editTitle} onChange={(event) => setEditTitle(event.target.value)} /></label>
        {candidate.intent && <label>対象日<input type="date" value={editDate} onChange={(event) => setEditDate(event.target.value)} /></label>}
        {candidate.kind === 'request' && <label>相手に送る文面<textarea rows={4} value={editMessage} onChange={(event) => setEditMessage(event.target.value)} /></label>}
        <div className="concierge-actions"><button type="button" disabled={!editTitle.trim() || resolvingId === candidate.candidateId} onClick={() => void saveEdit(candidate.candidateId)}>{resolvingId === candidate.candidateId ? '確認中…' : '編集を保存'}</button><button type="button" className="text-button" onClick={() => setEditingId(null)}>やめる</button></div>
      </div> : <button type="button" className="text-button" onClick={() => beginEdit(candidate)}>編集</button>}
      {candidate.kind === 'request' && !requestMessageIsReviewed(candidate) && <div className="card" role="alert">
        <b>送る文面の確認が必要です</b>
        <p className="meta">タイトル・日付・相手などの条件を変更した後は、古い文面をそのまま無確認では送れません。</p>
        {candidate.intent?.sharedMessage?.trim()
          ? <button type="button" className="secondary-button" onClick={() => confirmRequestMessage(candidate.candidateId)}>この文面でよい</button>
          : <p className="error-text">「編集」から相手に送る文面を入力してください。</p>}
      </div>}
    </div>)}
    {editError && <p role="alert" className="error-text">{editError}</p>}
    {state.clarification && <section className="card"><b>ここだけ確認</b><p>{state.clarification}</p></section>}
    {ambiguous.length > 0 && <section className="card"><b>ここだけ確認</b>{ambiguous.map((candidate) => <div key={candidate.candidateId}>
      <p>{candidate.title}：{candidate.missingFields.join(' / ')} が未確定です。</p>
      {candidate.missingFields.includes('assignee') && <div className="concierge-actions" aria-label={`${candidate.title}のお願い先`}><button type="button" disabled={resolvingId === candidate.candidateId} onClick={() => void resolveAssignee(candidate.candidateId, 'papa')}>パパにお願い</button><button type="button" disabled={resolvingId === candidate.candidateId} onClick={() => void resolveAssignee(candidate.candidateId, 'mama')}>ママにお願い</button></div>}
    </div>)}</section>}
    {visibleCandidates.length === 0 && <p className="empty-hint">登録候補を作れませんでした。戻って言い方を少し変えてください。</p>}
    <button type="button" className="concierge-wide" disabled={visibleCandidates.length === 0 || selected.size === 0 || ambiguous.some((candidate) => selected.has(candidate.candidateId)) || editingId !== null || resolvingId !== null} onClick={() => navigate('/concierge/confirm', { state: { ...state, candidates: visibleCandidates.filter((candidate) => selected.has(candidate.candidateId)) } })}>選択した内容をまとめて登録</button>
    <p className="meta">曖昧な部分だけ確認します。家庭内の言葉の意味を覚えても、担当ルールは勝手に変更しません。</p>
  </div>;
}

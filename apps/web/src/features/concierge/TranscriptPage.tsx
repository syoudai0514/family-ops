import { useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { FamilyOpsApiError } from '../../lib/apiClient';
import { proposeConciergeCandidates, saveConciergeDraft, type ConciergeRouteState } from './conciergeFlow';
import './concierge.css';

export function TranscriptPage() {
  const navigate = useNavigate();
  const location = useLocation();
  const state = (location.state ?? {}) as ConciergeRouteState;
  const [text, setText] = useState(state.draft ?? '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function organize() {
    const value = text.trim();
    if (!value) return setError('文字起こしを確認してください。');
    saveConciergeDraft(value);
    setBusy(true);
    setError(null);
    try {
      const result = await proposeConciergeCandidates(value);
      navigate('/concierge/results', { state: { ...state, draft: value, candidates: result.candidates, readOnlyIntent: result.read_only_intent, clarification: result.clarification } });
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '整理できませんでした。文字起こしは残っています。');
    } finally { setBusy(false); }
  }

  return <div className="app-shell concierge-page">
    <button type="button" className="text-button concierge-back" onClick={() => navigate(-1)}>‹ 戻る</button>
    <div className="eyebrow">🎙 音声入力</div><h1>文字起こしを確認</h1>
    <p className="page-lead">聞き間違い・言い直しをここで直せます。日付や担当など影響の大きい内容は次の確認画面でも表示します。</p>
    <label className="concierge-input-label"><span>文字起こし</span><textarea value={text} onChange={(event) => setText(event.target.value)} rows={8} /></label>
    {error && <p role="alert" className="error-text">{error}</p>}
    <button type="button" className="concierge-wide" disabled={busy} onClick={() => void organize()}>{busy ? '整理中…' : 'AIで整理'}</button>
  </div>;
}

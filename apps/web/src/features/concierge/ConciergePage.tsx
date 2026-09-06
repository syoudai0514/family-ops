import { useEffect, useMemo, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { FamilyOpsApiError } from '../../lib/apiClient';
import { loadConciergeDraft, proposeConciergeCandidates, saveConciergeDraft, type ConciergeRouteState } from './conciergeFlow';
import './concierge.css';

type SpeechRecognitionLike = {
  lang: string;
  interimResults: boolean;
  continuous: boolean;
  start: () => void;
  onresult: ((event: { results: ArrayLike<{ 0: { transcript: string } }> }) => void) | null;
  onerror: (() => void) | null;
};

type SpeechRecognitionCtor = new () => SpeechRecognitionLike;

function getSpeechRecognition(): SpeechRecognitionCtor | null {
  if (typeof window === 'undefined') return null;
  const value = window as typeof window & { SpeechRecognition?: SpeechRecognitionCtor; webkitSpeechRecognition?: SpeechRecognitionCtor };
  return value.SpeechRecognition ?? value.webkitSpeechRecognition ?? null;
}

export function ConciergePage({ actualOnly = false }: { actualOnly?: boolean }) {
  const navigate = useNavigate();
  const location = useLocation();
  const incoming = (location.state ?? {}) as ConciergeRouteState;
  const [text, setText] = useState(() => incoming.draft ?? loadConciergeDraft());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const speechAvailable = useMemo(() => Boolean(getSpeechRecognition()), []);

  useEffect(() => { saveConciergeDraft(text); }, [text]);

  const originState: ConciergeRouteState = {
    originPath: incoming.originPath ?? '/today',
    originScrollY: incoming.originScrollY ?? 0,
    actualOnly: actualOnly || incoming.actualOnly,
  };

  async function organize(source = text) {
    const value = source.trim();
    if (!value) {
      setError('内容を書いてください。');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const result = await proposeConciergeCandidates(value);
      navigate('/concierge/results', {
        state: { ...originState, draft: value, candidates: result.candidates, readOnlyIntent: result.read_only_intent, clarification: result.clarification },
      });
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '整理できませんでした。入力内容は残っています。');
    } finally {
      setBusy(false);
    }
  }

  function startVoice() {
    const Ctor = getSpeechRecognition();
    if (!Ctor) {
      setError('この端末では音声入力を開始できません。文字入力はそのまま使えます。');
      return;
    }
    const recognition = new Ctor();
    recognition.lang = 'ja-JP';
    recognition.interimResults = false;
    recognition.continuous = false;
    recognition.onresult = (event) => {
      const transcript = Array.from(event.results).map((result) => result[0]?.transcript ?? '').join(' ').trim();
      if (!transcript) return;
      saveConciergeDraft(transcript);
      navigate('/concierge/transcript', { state: { ...originState, draft: transcript } });
    };
    recognition.onerror = () => setError('音声を文字にできませんでした。文字入力はそのまま使えます。');
    recognition.start();
  }

  return (
    <div className="app-shell concierge-page">
      <button type="button" className="text-button concierge-back" onClick={() => navigate(-1)}>‹ 戻る</button>
      <div className="eyebrow">{actualOnly ? '予定外の実績' : '✨ Quick Add'}</div>
      <h1>{actualOnly ? '今日やったことを追加' : 'おうちコンシェルジュ'}</h1>
      <p className="page-lead">{actualOnly ? '何でも書いてください。頻用shortcut + free textで予定外作業を追加できます。' : '予定外のことを、書く・話すでまとめて入力。'}</p>
      {actualOnly ? (
        <div className="filter-chips" aria-label="よくある実績">
          {['掃除機', '買い物', '予約', '書類提出'].map((item) => <button key={item} type="button" className="secondary-button" onClick={() => setText((current) => current ? `${current}。${item}をやった` : `${item}をやった`)}>{item}</button>)}
        </div>
      ) : (
        <div className="filter-chips" aria-label="入力候補">
          {['予定', 'ToDo', '買い物', '共有', 'お願い', '実績'].map((item) => <span key={item} className="concierge-chip">{item}</span>)}
        </div>
      )}
      <label className="concierge-input-label">
        <span>何でも書いてください</span>
        <textarea value={text} onChange={(event) => setText(event.target.value)} rows={7} placeholder={actualOnly ? '例：掃除機かけた' : '例：明日は水遊び。水着を準備。牛乳がなくなりそう。金曜のお迎えお願い。'} />
      </label>
      {error && <p role="alert" className="error-text">{error}</p>}
      <div className="concierge-actions">
        {!actualOnly && <button type="button" className="secondary-button" disabled={!speechAvailable || busy} onClick={startVoice}>🎙 話す</button>}
        <button type="button" disabled={busy} onClick={() => void organize()}>{busy ? '整理中…' : actualOnly ? '実績候補を確認' : 'AIで整理'}</button>
      </div>
      <p className="meta">確認するまではToDo・お願い・買い物・共有・実績を作りません。質問は曖昧な部分だけ表示します。</p>
    </div>
  );
}

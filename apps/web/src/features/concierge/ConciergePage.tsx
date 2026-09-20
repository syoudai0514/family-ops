import { useEffect, useMemo, useRef, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useHousehold } from '../../app/HouseholdContext';
import { FamilyOpsApiError } from '../../lib/apiClient';
import { TaskFormModal } from '../tasks/TaskFormModal';
import { quickAddDestination, quickAddOptions } from '../tasks/QuickAdd';
import { conciergeDraftStorageKey, loadConciergeDraft, proposeConciergeCandidates, saveConciergeDraft, withActualScheduledDate, type ConciergeRouteState } from './conciergeFlow';
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

function todayInTokyo(): string {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Tokyo', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date());
  const get = (type: Intl.DateTimeFormatPartTypes) => parts.find((part) => part.type === type)?.value ?? '';
  return `${get('year')}-${get('month')}-${get('day')}`;
}

export function ConciergePage({ actualOnly = false }: { actualOnly?: boolean }) {
  const navigate = useNavigate();
  const location = useLocation();
  const { household, me } = useHousehold();
  const incoming = (location.state ?? {}) as ConciergeRouteState;
  const draftScope = useMemo(() => ({
    householdId: household?.id ?? null,
    userId: me?.user_id ?? null,
  }), [household?.id, me?.user_id]);
  const draftStorageKey = conciergeDraftStorageKey(draftScope);
  const loadedDraftKey = useRef<string | null>(null);
  const [text, setText] = useState(() => incoming.draft ?? '');
  const today = useMemo(() => todayInTokyo(), []);
  const [actualDate, setActualDate] = useState(today);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [taskFormOpen, setTaskFormOpen] = useState(false);
  const speechAvailable = useMemo(() => Boolean(getSpeechRecognition()), []);

  useEffect(() => {
    if (!draftStorageKey) return;
    if (loadedDraftKey.current !== draftStorageKey) {
      const initial = incoming.draft ?? loadConciergeDraft(draftScope);
      loadedDraftKey.current = draftStorageKey;
      if (initial !== text) setText(initial);
      if (incoming.draft !== undefined) saveConciergeDraft(draftScope, incoming.draft);
      return;
    }
    saveConciergeDraft(draftScope, text);
  }, [draftScope, draftStorageKey, incoming.draft, text]);

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
    if (actualOnly && !actualDate) {
      setError('実績の対象日を選んでください。');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const result = await proposeConciergeCandidates(value);
      const candidates = actualOnly ? withActualScheduledDate(result.candidates, actualDate) : result.candidates;
      navigate('/concierge/results', {
        state: { ...originState, draft: value, candidates, readOnlyIntent: result.read_only_intent, clarification: result.clarification },
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
      saveConciergeDraft(draftScope, transcript);
      navigate('/concierge/transcript', { state: { ...originState, draft: transcript } });
    };
    recognition.onerror = () => setError('音声を文字にできませんでした。文字入力はそのまま使えます。');
    recognition.start();
  }

  return (
    <div className="app-shell concierge-page">
      <button type="button" className="text-button concierge-back" onClick={() => navigate(-1)}>‹ 戻る</button>
      <div className="eyebrow">{actualOnly ? '予定外の実績' : '追加'}</div>
      <h1>{actualOnly ? 'やったことを追加' : '追加'}</h1>
      <p className="page-lead">{actualOnly ? '予定になかった家事・育児も、実際にやった日を選んで記録できます。' : '思いついたことを、そのまま書いてください。分類はあとで整理します。'}</p>
      {actualOnly && (
        <>
          <label className="concierge-input-label"><span>実際にやった日</span><input type="date" value={actualDate} max={today} onChange={(event) => setActualDate(event.target.value)} /></label>
          <div className="filter-chips" aria-label="よくある実績">
            {['掃除機', '買い物', '予約', '書類提出'].map((item) => <button key={item} type="button" className="secondary-button" onClick={() => setText((current) => current ? `${current}。${item}をやった` : `${item}をやった`)}>{item}</button>)}
          </div>
        </>
      )}
      <label className="concierge-input-label">
        <span>{actualOnly ? '何をやったか書いてください' : '思いついたことを、そのまま書いてください'}</span>
        <textarea value={text} onChange={(event) => setText(event.target.value)} rows={7} placeholder={actualOnly ? '例：掃除機かけた' : '例：明日は水遊び。水着を準備。牛乳がなくなりそう。金曜のお迎えお願い。'} />
      </label>
      {error && <p role="alert" className="error-text">{error}</p>}
      <div className="concierge-actions">
        {!actualOnly && <button type="button" className="secondary-button" disabled={!speechAvailable || busy} onClick={startVoice}>🎙 話す</button>}
        <button type="button" disabled={busy} onClick={() => void organize()}>{busy ? '確認内容を作成中…' : actualOnly ? '実績候補を確認' : '内容を確認'}</button>
      </div>
      {!actualOnly && <details className="card">
        <summary><b>選んで入力</b></summary>
        <p className="meta">自由入力が合わない時だけ、今までの入力画面を選べます。</p>
        <div className="quick-add-list">
          {quickAddOptions.map((option) => (
            <button key={option.target} type="button" onClick={() => {
              if (option.target === 'task') {
                setTaskFormOpen(true);
                return;
              }
              navigate(quickAddDestination(option.target), { state: originState });
            }}>
              <b>{option.label}</b>
              {option.detail && <small>{option.detail}</small>}
            </button>
          ))}
        </div>
      </details>}
      <p className="meta">確認するまでは、登録も家族への送信もしません。</p>
      {taskFormOpen && <TaskFormModal
        mode="create"
        onClose={() => setTaskFormOpen(false)}
        onSaved={() => {
          setTaskFormOpen(false);
          navigate(originState.originPath ?? '/today', { replace: true, state: { restoreScrollY: originState.originScrollY ?? 0 } });
        }}
      />}
    </div>
  );
}

import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useHousehold } from '../../app/HouseholdContext';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';

type TemplateKey = 'birthday' | 'school' | 'medical' | 'ceremony' | 'trip' | 'custom';
type CandidateSource = 'template' | 'ai';

interface EventCandidate {
  candidate_id: string;
  source: CandidateSource;
  title: string;
  scheduled_date: string;
  reason?: string;
}

interface EventDraftResponse {
  draft_id: string;
  revision: number;
  status: 'draft';
  template_key: TemplateKey;
  input: { title: string; event_date: string; details?: string; location?: string };
  template_candidates: EventCandidate[];
  ai_candidates: EventCandidate[];
}

interface ReviewedCandidate extends EventCandidate {
  selected: boolean;
  planned_assignee_user_id: string;
}

const TEMPLATE_LABELS: Record<TemplateKey, string> = {
  birthday: '誕生日',
  school: '園・学校行事',
  medical: '通院・予防接種',
  ceremony: '式典・家族行事',
  trip: '旅行・外出',
  custom: 'その他',
};

export function selectedTodosForConfirm(candidates: ReviewedCandidate[]) {
  return candidates.filter((candidate) => candidate.selected).map((candidate) => ({
    candidate_id: candidate.candidate_id,
    title: candidate.title.trim(),
    scheduled_date: candidate.scheduled_date,
    planned_assignee_user_id: candidate.planned_assignee_user_id || null,
  }));
}

function todayIso(): string {
  const now = new Date();
  const local = new Date(now.getTime() - now.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 10);
}

export function EventPlanPage() {
  const navigate = useNavigate();
  const { members } = useHousehold();
  const [templateKey, setTemplateKey] = useState<TemplateKey>('school');
  const [title, setTitle] = useState('');
  const [eventDate, setEventDate] = useState(todayIso());
  const [location, setLocation] = useState('');
  const [details, setDetails] = useState('');
  const [draft, setDraft] = useState<EventDraftResponse | null>(null);
  const [candidates, setCandidates] = useState<ReviewedCandidate[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const selectedCount = useMemo(() => candidates.filter((candidate) => candidate.selected).length, [candidates]);

  async function propose() {
    setBusy(true);
    setError(null);
    try {
      const result = await callEdgeFunction<EventDraftResponse>(EDGE_FUNCTIONS.proposeEventPlan, {
        operation_id: newOperationId(),
        template_key: templateKey,
        title,
        event_date: eventDate,
        location,
        details,
      });
      setDraft(result);
      setTitle(result.input.title);
      setEventDate(result.input.event_date);
      setLocation(result.input.location ?? '');
      setDetails(result.input.details ?? '');
      setCandidates([...result.template_candidates, ...result.ai_candidates].map((candidate) => ({
        ...candidate,
        selected: true,
        planned_assignee_user_id: '',
      })));
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '準備候補を作れませんでした。');
    } finally {
      setBusy(false);
    }
  }

  function updateCandidate(id: string, patch: Partial<ReviewedCandidate>) {
    setCandidates((rows) => rows.map((row) => row.candidate_id === id ? { ...row, ...patch } : row));
  }

  async function confirm() {
    if (!draft) return;
    const selected = selectedTodosForConfirm(candidates);
    if (selected.some((todo) => !todo.title)) {
      setError('登録する準備ToDoの名前を入力してください。');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.confirmEventPlan, {
        operation_id: newOperationId(),
        draft_id: draft.draft_id,
        expected_revision: draft.revision,
        reviewed_event: { title, event_date: eventDate, location, details },
        selected_todos: selected,
      });
      navigate('/week');
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : 'イベントを登録できませんでした。');
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="app-shell">
      <div className="page-heading">
        <div>
          <p className="eyebrow">イベント・準備</p>
          <h1>予定と準備をまとめて作る</h1>
          <p className="page-lead">入力内容とテンプレート、AI候補を見比べて、必要なものだけ確定します。</p>
        </div>
        <Link to="/week" className="secondary-button">戻る</Link>
      </div>

      <section className="card stack-form" aria-labelledby="event-plan-title">
        <h2 id="event-plan-title">1. イベント内容</h2>
        <label>種類
          <select value={templateKey} disabled={Boolean(draft)} onChange={(event) => setTemplateKey(event.target.value as TemplateKey)}>
            {Object.entries(TEMPLATE_LABELS).map(([key, label]) => <option key={key} value={key}>{label}</option>)}
          </select>
        </label>
        <label>イベント名<input value={title} maxLength={240} onChange={(event) => setTitle(event.target.value)} placeholder="例：運動会" /></label>
        <label>日付<input type="date" value={eventDate} onChange={(event) => setEventDate(event.target.value)} /></label>
        <label>場所<input value={location} maxLength={500} onChange={(event) => setLocation(event.target.value)} placeholder="例：保育園" /></label>
        <label>わかっていること<textarea value={details} maxLength={4000} rows={4} onChange={(event) => setDetails(event.target.value)} placeholder="持ち物や集合時間など、わかる範囲で" /></label>
        {!draft && <button type="button" className="hero-primary" disabled={busy || !title.trim() || !eventDate} onClick={propose}>{busy ? '候補を作成中…' : '準備候補を作る'}</button>}
      </section>

      {draft && (
        <section className="card stack-form" aria-labelledby="event-review-title">
          <h2 id="event-review-title">2. 準備ToDoを確認</h2>
          <p className="empty-hint">AI候補もテンプレート候補も、ここで「登録する」にしたものだけが確定時に登録されます。AIの推測だけでは登録されません。</p>
          {candidates.length === 0 && <p>準備候補はありません。イベントだけ登録できます。</p>}
          {candidates.map((candidate) => (
            <article key={candidate.candidate_id} className="task-item-card">
              <label className="subtask-check-row">
                <input type="checkbox" checked={candidate.selected} onChange={(event) => updateCandidate(candidate.candidate_id, { selected: event.target.checked })} />
                <span><b>{candidate.source === 'template' ? 'テンプレート' : 'AI候補'}</b> — 登録する</span>
              </label>
              <label>準備ToDo<input disabled={!candidate.selected} value={candidate.title} maxLength={240} onChange={(event) => updateCandidate(candidate.candidate_id, { title: event.target.value })} /></label>
              <label>いつまで<input disabled={!candidate.selected} type="date" max={eventDate} value={candidate.scheduled_date} onChange={(event) => updateCandidate(candidate.candidate_id, { scheduled_date: event.target.value })} /></label>
              <label>担当
                <select disabled={!candidate.selected} value={candidate.planned_assignee_user_id} onChange={(event) => updateCandidate(candidate.candidate_id, { planned_assignee_user_id: event.target.value })}>
                  <option value="">未定</option>
                  {members.map((member) => <option key={member.user_id} value={member.user_id}>{member.profile?.display_name || (member.family_role === 'papa' ? 'パパ' : member.family_role === 'mama' ? 'ママ' : '家族')}</option>)}
                </select>
              </label>
              {candidate.source === 'ai' && candidate.reason && <p className="empty-hint">AIの理由: {candidate.reason}</p>}
            </article>
          ))}
          <p className="empty-hint">登録予定: イベント1件 / 準備ToDo {selectedCount}件。イベント全体の担当者は作りません。</p>
          {error && <p role="alert" className="error-text">{error}</p>}
          <button type="button" className="hero-primary" disabled={busy || !title.trim() || !eventDate} onClick={confirm}>{busy ? '登録中…' : 'この内容で確定する'}</button>
        </section>
      )}
      {!draft && error && <p role="alert" className="error-text">{error}</p>}
    </main>
  );
}

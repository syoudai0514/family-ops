import { useEffect, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { useCommandAttempt } from '../../lib/useCommandAttempt';

type Candidate = {
  kind: 'task' | 'request';
  id: string;
  title: string;
  recipient_id: string;
  activity_date?: string;
  target_date?: string | null;
};
type CandidateRow = Candidate & { sent?: boolean; error?: string };

function candidateKey(candidate: Candidate) {
  return `${candidate.kind}:${candidate.id}`;
}

export function ThanksPrompt({ refreshKey }: { refreshKey: unknown }) {
  const { household, members } = useHousehold();
  const [candidates, setCandidates] = useState<CandidateRow[]>([]);
  const [sendingKey, setSendingKey] = useState<string | null>(null);
  const run = useCommandAttempt();

  useEffect(() => {
    if (!household?.id) return;
    let active = true;
    void callEdgeFunction<Candidate[]>(EDGE_FUNCTIONS.editTask, {
      operation_id: newOperationId(), action: 'list_thanks',
    }).then((rows) => {
      if (!active || !Array.isArray(rows)) return;
      setCandidates((previous) => {
        // Keep a sent row in place, including while an older read is resolving.
        const incoming = new Map(rows.map((row) => [candidateKey(row), row]));
        if (!previous.some((row) => row.sent)) return [...incoming.values()];
        const retained = previous.flatMap((row) => {
          const key = candidateKey(row);
          const updated = incoming.get(key);
          incoming.delete(key);
          return row.sent ? [row] : updated ? [{ ...updated, error: row.error }] : [];
        });
        return [...retained, ...incoming.values()];
      });
    }).catch(() => { /* Keep the currently visible state on refresh failure. */ });
    return () => { active = false; };
  }, [household?.id, refreshKey]);

  async function send(candidate: Candidate, note?: string) {
    const key = candidateKey(candidate);
    setSendingKey(key);
    try {
      await run(`thanks:${key}`, EDGE_FUNCTIONS.editTask, (operationId) => ({
        operation_id: operationId, action: 'send_thanks', source_kind: candidate.kind, source_id: candidate.id, note: note?.trim() || null,
      }));
      updateRow({ ...candidate, sent: true, error: undefined });
    } catch (err) {
      updateRow({ ...candidate, error: err instanceof Error ? err.message : '送れませんでした。もう一度お試しください。' });
    } finally {
      setSendingKey(null);
    }

    function updateRow(updated: CandidateRow) {
      setCandidates((rows) => rows.some((row) => candidateKey(row) === key)
        ? rows.map((row) => candidateKey(row) === key ? updated : row)
        : [updated, ...rows]);
    }
  }

  function renderItem(candidate: CandidateRow) {
    const member = members.find((item) => item.user_id === candidate.recipient_id);
    const name = member?.family_role === 'mama' ? 'ママ' : member?.family_role === 'papa' ? 'パパ' : member?.profile?.display_name ?? '家族';
    const key = candidateKey(candidate);
    return <ThanksItem key={key} candidate={candidate} name={name}
      busy={sendingKey !== null} sending={sendingKey === key} onSend={(note) => void send(candidate, note)} />;
  }

  const [first, ...others] = candidates;
  if (!first) return null;
  return <section className="card compact-section thanks-prompt" aria-label="ありがとう">
    {renderItem(first)}
    {others.length > 0 && <details className="thanks-more">
      <summary>ほかの候補を見る</summary>
      {others.map(renderItem)}
    </details>}
  </section>;
}

function ThanksItem({ candidate, name, busy, sending, onSend }: {
  candidate: CandidateRow; name: string; busy: boolean; sending: boolean; onSend: (note?: string) => void;
}) {
  const [note, setNote] = useState('');
  const date = candidate.target_date ?? candidate.activity_date;
  const dateLabel = date && new Intl.DateTimeFormat('ja-JP', {
    timeZone: 'Asia/Tokyo', month: 'long', day: 'numeric',
  }).format(new Date(`${date}T00:00:00+09:00`));

  return <div className="thanks-item">
    <div className="section-heading thanks-item-heading">
      <div>
        {date && <time dateTime={date} className="task-item-meta">{dateLabel}</time>}
        <p>{name}が「{candidate.title}」を{candidate.kind === 'task' ? '代わってくれました' : '引き受けてくれました'}</p>
      </div>
      {candidate.sent ? <p role="status" className="thanks-sent">✓ 送信済み</p> : (
        <button type="button" className="secondary-button" disabled={busy} onClick={() => onSend()}>
          {sending ? '送信中…' : 'ありがとうを送る'}
        </button>
      )}
    </div>
    {!candidate.sent && <details><summary>ひとこと添える</summary>
      <label>メッセージ<textarea value={note} maxLength={300} onChange={(event) => setNote(event.target.value)} /></label>
      <button type="button" disabled={busy || !note.trim()} onClick={() => onSend(note)}>添えて送る</button>
    </details>}
    {candidate.error && !sending && <p role="alert" className="error-text">{candidate.error}</p>}
  </div>;
}

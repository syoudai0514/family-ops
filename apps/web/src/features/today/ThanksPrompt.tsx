import { useEffect, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { useCommandAttempt } from '../../lib/useCommandAttempt';

type Candidate = { kind: 'task' | 'request'; id: string; title: string; recipient_id: string };

export function ThanksPrompt({ refreshKey }: { refreshKey: unknown }) {
  const { household, members } = useHousehold();
  const [candidates, setCandidates] = useState<Candidate[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const run = useCommandAttempt();

  useEffect(() => {
    if (!household?.id) return;
    let active = true;
    void callEdgeFunction<Candidate[]>(EDGE_FUNCTIONS.editTask, {
      operation_id: newOperationId(), action: 'list_thanks',
    }).then((rows) => { if (active) setCandidates(Array.isArray(rows) ? rows : []); }).catch(() => { if (active) setCandidates([]); });
    return () => { active = false; };
  }, [household?.id, refreshKey]);

  async function send(candidate: Candidate, note?: string) {
    setBusy(candidate.id);
    setError(null);
    try {
      await run(`thanks:${candidate.kind}:${candidate.id}`, EDGE_FUNCTIONS.editTask, (operationId) => ({
        operation_id: operationId, action: 'send_thanks', source_kind: candidate.kind, source_id: candidate.id, note: note?.trim() || null,
      }));
      setCandidates((items) => items.filter((item) => item.id !== candidate.id || item.kind !== candidate.kind));
      setNotice('ありがとうを送りました。');
    } catch (err) {
      setError(err instanceof Error ? err.message : '送れませんでした。もう一度お試しください。');
    } finally {
      setBusy(null);
    }
  }

  if (!candidates.length && !notice && !error) return null;
  return <section className="card compact-section" aria-label="ありがとう">
    {candidates.map((candidate) => {
      const member = members.find((item) => item.user_id === candidate.recipient_id);
      const name = member?.family_role === 'mama' ? 'ママ' : member?.family_role === 'papa' ? 'パパ' : member?.profile?.display_name ?? '家族';
      return <ThanksItem key={`${candidate.kind}:${candidate.id}`} candidate={candidate} name={name}
        busy={busy !== null} sending={busy === candidate.id} onSend={(note) => void send(candidate, note)} />;
    })}
    {notice && <p role="status">{notice}</p>}
    {error && <p role="alert" className="error-text">{error}</p>}
  </section>;
}

function ThanksItem({ candidate, name, busy, sending, onSend }: {
  candidate: Candidate; name: string; busy: boolean; sending: boolean; onSend: (note?: string) => void;
}) {
  const [note, setNote] = useState('');
  return <div>
    <div className="section-heading">
      <span>{name}が「{candidate.title}」を{candidate.kind === 'task' ? '代わってくれました' : '引き受けてくれました'}</span>
      <button type="button" className="secondary-button" disabled={busy} onClick={() => onSend()}>
        {sending ? '送信中…' : 'ありがとうを送る'}
      </button>
    </div>
    <details><summary>ひとこと添える</summary>
      <label>メッセージ<textarea value={note} maxLength={300} onChange={(event) => setNote(event.target.value)} /></label>
      <button type="button" disabled={busy || !note.trim()} onClick={() => onSend(note)}>添えて送る</button>
    </details>
  </div>;
}

import { useEffect, useState, type FormEvent } from 'react';
import { Modal } from '../../components/Modal';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';

type EventDate = { date?: string; dateTime?: string };
type GoogleEvent = { etag: string; title: string; location: string; description: string; start: EventDate; end: EventDate; recurring: boolean };

function addDay(value: string, days: number) {
  const date = new Date(`${value}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}
function tokyoLocal(value: string) {
  const parts = new Intl.DateTimeFormat('sv-SE', {
    timeZone: 'Asia/Tokyo', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(new Date(value));
  return parts.replace(' ', 'T');
}

export function GoogleEventEditor({ occurrenceId, onClose, onSaved }: { occurrenceId: string; onClose: () => void; onSaved: (syncRequested: boolean) => void }) {
  const [event, setEvent] = useState<GoogleEvent | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let active = true;
    void callEdgeFunction<GoogleEvent>(EDGE_FUNCTIONS.editTask, { operation_id: newOperationId(), action: 'read_google_event', occurrence_id: occurrenceId })
      .then((value) => { if (active) setEvent(value); })
      .catch((err) => { if (active) setError(err instanceof Error ? err.message : '予定を読み込めませんでした。'); });
    return () => { active = false; };
  }, [occurrenceId]);
  return <Modal title="Googleの予定を編集" onClose={onClose}>
    {error && <p role="alert" className="error-text">{error}</p>}
    {event ? <GoogleEventForm event={event} occurrenceId={occurrenceId} onClose={onClose} onSaved={onSaved} /> : !error && <p role="status">読み込み中…</p>}
  </Modal>;
}

function GoogleEventForm({ event, occurrenceId, onClose, onSaved }: { event: GoogleEvent; occurrenceId: string; onClose: () => void; onSaved: (syncRequested: boolean) => void }) {
  const [title, setTitle] = useState(event.title);
  const [location, setLocation] = useState(event.location);
  const [description, setDescription] = useState(event.description);
  const [allDay, setAllDay] = useState(Boolean(event.start.date));
  const originalAllDay = Boolean(event.start.date);
  const originalStart = originalAllDay ? event.start.date! : tokyoLocal(event.start.dateTime!);
  const originalEnd = originalAllDay ? addDay(event.end.date!, -1) : tokyoLocal(event.end.dateTime!);
  const [start, setStart] = useState(originalStart);
  const [end, setEnd] = useState(originalEnd);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save(e: FormEvent) {
    e.preventDefault();
    const changes: Record<string, unknown> = {};
    if (title !== event.title) changes.summary = title;
    if (location !== event.location) changes.location = location;
    if (description !== event.description) changes.description = description;
    if (allDay !== originalAllDay || start !== originalStart || end !== originalEnd) {
      changes.start = allDay ? { date: start } : { dateTime: `${start}:00+09:00` };
      changes.end = allDay ? { date: addDay(end, 1) } : { dateTime: `${end}:00+09:00` };
    }
    if (!Object.keys(changes).length) { onClose(); return; }
    setBusy(true);
    setError(null);
    try {
      const result = await callEdgeFunction<{ saved: boolean; syncRequested: boolean }>(EDGE_FUNCTIONS.editTask, {
        operation_id: newOperationId(), action: 'save_google_event', occurrence_id: occurrenceId, etag: event.etag, changes,
      });
      onSaved(result.syncRequested);
    } catch (err) {
      setError(err instanceof Error ? err.message : '保存できませんでした。');
    } finally { setBusy(false); }
  }

  function changeAllDay(value: boolean) {
    setAllDay(value);
    if (value) { setStart(start.slice(0, 10)); setEnd(end.slice(0, 10)); }
    else { setStart(`${start.slice(0, 10)}T09:00`); setEnd(`${end.slice(0, 10)}T10:00`); }
  }

  return <form className="stack-form" onSubmit={(e) => void save(e)}>
    {event.recurring && <p>繰り返し予定の、この1回を編集します。</p>}
    <label>予定名<input value={title} onChange={(e) => setTitle(e.target.value)} required /></label>
    <label className="checkbox-row"><input type="checkbox" checked={allDay} onChange={(e) => changeAllDay(e.target.checked)} />終日</label>
    <label>開始<input type={allDay ? 'date' : 'datetime-local'} value={start} onChange={(e) => setStart(e.target.value)} required /></label>
    <label>終了<input type={allDay ? 'date' : 'datetime-local'} value={end} onChange={(e) => setEnd(e.target.value)} required /></label>
    <label>場所<input value={location} onChange={(e) => setLocation(e.target.value)} /></label>
    <label>内容<textarea value={description} onChange={(e) => setDescription(e.target.value)} rows={4} /></label>
    {error && <p role="alert" className="error-text">{error}</p>}
    <button type="submit" disabled={busy}>{busy ? '保存中…' : 'Googleカレンダーに保存'}</button>
  </form>;
}

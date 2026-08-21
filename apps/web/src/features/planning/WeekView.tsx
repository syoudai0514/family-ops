import { Link } from 'react-router-dom';
import { useMemo, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { formatTimeJa } from '../../lib/date';
import { addDays, formatShortDate, localIsoDate, mondayOf } from './dateHelpers';
import { usePlanningData } from './usePlanningData';

export function WeekView() {
  const { household, members } = useHousehold();
  const [weekStart, setWeekStart] = useState(() => mondayOf(new Date()));
  const days = useMemo(() => Array.from({ length: 7 }, (_, i) => addDays(weekStart, i)), [weekStart]);
  const { loading, error, events } = usePlanningData(household?.id ?? null, localIsoDate(days[0]), localIsoDate(days[6]));
  const nameFor = (id: string | null) => members.find((member) => member.user_id === id)?.profile?.display_name ?? '';
  return <main className="app-shell planning-page">
    <div className="today-header"><div><p className="eyebrow">家族の見通し</p><h1>今週</h1></div><Link className="button-link" to="/requests">お願いする</Link></div>
    <div className="period-control"><button onClick={() => setWeekStart(addDays(weekStart, -7))}>前週</button><strong>{formatShortDate(days[0])} 〜 {formatShortDate(days[6])}</strong><button onClick={() => setWeekStart(addDays(weekStart, 7))}>次週</button></div>
    {error && <p role="alert" className="error-text">{error}</p>}
    {loading ? <p role="status">読み込み中…</p> : <div className="week-cards">
      {days.map((day) => { const date = localIsoDate(day); const dayEvents = events.filter((event) => event.date === date); return <section className="week-day-card" key={date}><h2>{formatShortDate(day)}</h2>{dayEvents.length === 0 ? <p className="empty-hint">予定なし</p> : <ul>{dayEvents.map((event) => <li key={`${event.kind}-${event.id}`} className={event.kind === 'calendar' ? 'calendar-event' : 'task-event'}><span>{event.time ? formatTimeJa(event.time) : '終日'}</span><strong>{event.title}</strong>{event.assigneeId && <small>担当: {nameFor(event.assigneeId)}</small>}</li>)}</ul>}<Link to={`/requests?date=${date}`} className="day-action">この日の担当を相談</Link></section>; })}
    </div>}
  </main>;
}

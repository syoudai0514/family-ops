import { useMemo, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { localIsoDate } from './dateHelpers';
import { usePlanningData } from './usePlanningData';

function monthRange(anchor: Date) { const start = new Date(anchor.getFullYear(), anchor.getMonth(), 1); const end = new Date(anchor.getFullYear(), anchor.getMonth() + 1, 0); return { start, end }; }
export function MonthView() {
  const { household } = useHousehold(); const [anchor, setAnchor] = useState(() => new Date()); const { start, end } = monthRange(anchor);
  const { events, loading, error } = usePlanningData(household?.id ?? null, localIsoDate(start), localIsoDate(end));
  const [selected, setSelected] = useState(localIsoDate(new Date()));
  const days = useMemo(() => Array.from({ length: end.getDate() }, (_, i) => new Date(anchor.getFullYear(), anchor.getMonth(), i + 1)), [anchor, end]);
  const firstOffset = (start.getDay() + 6) % 7;
  const totalCells = firstOffset + days.length > 35 ? 42 : 35;
  const changeMonth = (delta: number) => { const next = new Date(anchor.getFullYear(), anchor.getMonth() + delta, 1); setAnchor(next); setSelected(localIsoDate(next)); };
  return <main className="app-shell planning-page"><div className="today-header"><div><p className="eyebrow">全体を把握</p><h1>{anchor.getFullYear()}年{anchor.getMonth() + 1}月</h1></div></div><div className="period-control"><button onClick={() => changeMonth(-1)}>前月</button><button onClick={() => changeMonth(1)}>次月</button></div>{error && <p role="alert" className="error-text">{error}</p>}{loading ? <p role="status">読み込み中…</p> : <><div className="month-grid month-weekdays" aria-hidden="true">{['月','火','水','木','金','土','日'].map((day) => <span key={day}>{day}</span>)}</div><div className="month-grid" aria-label="月間カレンダー">{Array.from({ length: totalCells }, (_, index) => { const day = days[index - firstOffset]; if (!day) return <span className="month-day empty" key={`empty-${index}`} />; const date = localIsoDate(day); const dayEvents = events.filter((event) => event.date === date); return <button key={date} onClick={() => setSelected(date)} className={selected === date ? 'month-day selected' : 'month-day'}><span>{day.getDate()}</span>{dayEvents.slice(0, 2).map((event) => <small key={`${event.kind}-${event.id}`} className={event.kind}>{event.title}</small>)}{dayEvents.length > 2 && <small>ほか {dayEvents.length - 2}件</small>}</button>; })}</div><section className="card day-detail"><h2>{selected} の予定</h2>{events.filter((event) => event.date === selected).length === 0 ? <p className="empty-hint">予定はありません</p> : <ul>{events.filter((event) => event.date === selected).map((event) => <li key={`${event.kind}-${event.id}`}>{event.title}</li>)}</ul>}</section></>}</main>;
}

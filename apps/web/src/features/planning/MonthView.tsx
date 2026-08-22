import { useMemo, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { localIsoDate } from './dateHelpers';
import { usePlanningData } from './usePlanningData';
import { assigneeToken, buildCalendarProjection, transportLabel } from './calendarProjection';

function monthRange(anchor: Date) {
  const start = new Date(anchor.getFullYear(), anchor.getMonth(), 1);
  const end = new Date(anchor.getFullYear(), anchor.getMonth() + 1, 0);
  return { start, end };
}
export function MonthView() {
  const { household, members } = useHousehold();
  const [anchor, setAnchor] = useState(() => new Date());
  const { start, end } = monthRange(anchor);
  const { tasks, occurrences, loading, error } = usePlanningData(
    household?.id ?? null,
    localIsoDate(start),
    localIsoDate(end),
  );
  const [selected, setSelected] = useState(localIsoDate(new Date()));
  const primaryUserId = members.find((member) => member.member_role === 'primary')?.user_id ?? null;
  const partnerUserId = members.find((member) => member.member_role === 'partner')?.user_id ?? null;
  const projection = useMemo(
    () => buildCalendarProjection({ tasks, occurrences, primaryUserId, partnerUserId }),
    [occurrences, partnerUserId, primaryUserId, tasks],
  );
  const days = useMemo(
    () =>
      Array.from(
        { length: end.getDate() },
        (_, i) => new Date(anchor.getFullYear(), anchor.getMonth(), i + 1),
      ),
    [anchor, end],
  );
  const firstOffset = (start.getDay() + 6) % 7;
  const totalCells = firstOffset + days.length > 35 ? 42 : 35;
  const changeMonth = (delta: number) => {
    const next = new Date(anchor.getFullYear(), anchor.getMonth() + delta, 1);
    setAnchor(next);
    setSelected(localIsoDate(next));
  };
  return (
    <main className="app-shell planning-page">
      <div className="today-header">
        <div>
          <p className="eyebrow">全体を把握</p>
          <h1>
            {anchor.getFullYear()}年{anchor.getMonth() + 1}月
          </h1>
        </div>
      </div>
      <div className="period-control">
        <button onClick={() => changeMonth(-1)}>前月</button>
        <button onClick={() => changeMonth(1)}>次月</button>
      </div>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      {loading ? (
        <p role="status">読み込み中…</p>
      ) : (
        <>
          <div className="month-grid month-weekdays" aria-hidden="true">
            {['月', '火', '水', '木', '金', '土', '日'].map((day) => (
              <span key={day}>{day}</span>
            ))}
          </div>
          <div className="month-grid" aria-label="月間カレンダー">
            {Array.from({ length: totalCells }, (_, index) => {
              const day = days[index - firstOffset];
              if (!day) return <span className="month-day empty" key={`empty-${index}`} />;
              const date = localIsoDate(day);
              const transport = projection.transportByDate.get(date);
              const dayItems = projection.itemsByDate.get(date) ?? [];
              return (
                <button
                  key={date}
                  onClick={() => setSelected(date)}
                  className={selected === date ? 'month-day selected' : 'month-day'}
                >
                  <span>{day.getDate()}</span>
                  {transport && (
                    <small className="transport-row">
                      {transportLabel(transport, primaryUserId, partnerUserId)}
                    </small>
                  )}
                  {dayItems.slice(0, 2).map((item) => (
                    <small key={item.id} className={`projection-row ${item.source}`}>
                      {item.shortTitle} <b>{assigneeToken(item.ownerKind)}</b>
                    </small>
                  ))}
                  {dayItems.length > 2 && <small className="month-more">+{dayItems.length - 2}</small>}
                </button>
              );
            })}
          </div>
          <section className="card day-detail">
            <h2>{selected} の予定</h2>
            {!projection.transportByDate.get(selected) && (projection.itemsByDate.get(selected) ?? []).length === 0 ? (
              <p className="empty-hint">予定はありません</p>
            ) : (
              <ul>
                {projection.transportByDate.get(selected) && (
                  <li>{transportLabel(projection.transportByDate.get(selected), primaryUserId, partnerUserId)}</li>
                )}
                {(projection.itemsByDate.get(selected) ?? []).map((item) => (
                  <li key={item.id}>
                    {item.fullTitle} <small>[{assigneeToken(item.ownerKind)}]</small>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </>
      )}
    </main>
  );
}

import { useMemo, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { mamaUserId, papaUserId } from '../../lib/familyRoles';
import {
  assigneeToken,
  buildCalendarProjection,
  transportTokens,
  type CalendarProjectionItem,
} from './calendarProjection';
import { localIsoDate } from './dateHelpers';
import { usePlanningData } from './usePlanningData';
import './MonthView.css';

function monthRange(anchor: Date) {
  const start = new Date(anchor.getFullYear(), anchor.getMonth(), 1);
  const end = new Date(anchor.getFullYear(), anchor.getMonth() + 1, 0);
  return { start, end };
}

function compactClock(value: string | null) {
  if (!value) return '';
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return '';
  return new Intl.DateTimeFormat('ja-JP', {
    timeZone: 'Asia/Tokyo',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  })
    .format(parsed)
    .replace(':', '');
}

function compactEventTitle(item: CalendarProjectionItem) {
  const title = item.fullTitle.trim();
  if (item.allDay) return title;
  const withoutLeadingTime = title.replace(/^\s*\d{1,2}(?::\d{2}|時(?:\d{1,2}分?)?)\s*/, '');
  return withoutLeadingTime || title;
}

function selectedDateLabel(date: string) {
  const parsed = new Date(`${date}T00:00:00`);
  if (Number.isNaN(parsed.getTime())) return date;
  return new Intl.DateTimeFormat('ja-JP', {
    month: 'long',
    day: 'numeric',
    weekday: 'short',
  }).format(parsed);
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
  const [detail, setDetail] = useState<CalendarProjectionItem | null>(null);
  const primaryUserId = papaUserId(members);
  const partnerUserId = mamaUserId(members);
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
  const today = localIsoDate(new Date());

  const changeMonth = (delta: number) => {
    const next = new Date(anchor.getFullYear(), anchor.getMonth() + delta, 1);
    setAnchor(next);
    setSelected(localIsoDate(next));
    setDetail(null);
  };

  const selectedTransport = projection.transportByDate.get(selected);
  const selectedTokens = transportTokens(selectedTransport, primaryUserId, partnerUserId);
  const selectedHasTransport =
    selectedTokens.dropoff.token !== '—' || selectedTokens.pickup.token !== '—';

  return (
    <main className="app-shell planning-page month-page">
      <div className="month-toolbar" aria-label="月の移動">
        <button
          type="button"
          className="month-nav-button"
          aria-label="前月"
          onClick={() => changeMonth(-1)}
        >
          ‹
        </button>
        <div className="month-title-wrap">
          <p className="eyebrow">全体を把握</p>
          <h1>
            {anchor.getFullYear()}年{anchor.getMonth() + 1}月
          </h1>
        </div>
        <button
          type="button"
          className="month-nav-button"
          aria-label="次月"
          onClick={() => changeMonth(1)}
        >
          ›
        </button>
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
          <div className="month-grid month-calendar" aria-label="月間カレンダー">
            {Array.from({ length: totalCells }, (_, index) => {
              const day = days[index - firstOffset];
              if (!day) return <span className="month-day empty" key={`empty-${index}`} />;
              const date = localIsoDate(day);
              const transport = projection.transportByDate.get(date);
              const dayItems = projection.itemsByDate.get(date) ?? [];
              const tokens = transportTokens(transport, primaryUserId, partnerUserId);
              const hasTransport =
                tokens.dropoff.token !== '—' || tokens.pickup.token !== '—';
              const visibleItemLimit = hasTransport ? 2 : 3;
              const visibleItems = dayItems.slice(0, visibleItemLimit);
              const hiddenCount = Math.max(0, dayItems.length - visibleItems.length);
              const dayOfWeek = day.getDay();

              return (
                <button
                  key={date}
                  type="button"
                  onClick={() => {
                    setSelected(date);
                    setDetail(null);
                  }}
                  aria-pressed={selected === date}
                  className={[
                    'month-day',
                    selected === date ? 'selected' : '',
                    date === today ? 'today' : '',
                    dayOfWeek === 6 ? 'saturday' : '',
                    dayOfWeek === 0 ? 'sunday' : '',
                  ]
                    .filter(Boolean)
                    .join(' ')}
                >
                  <span className="month-date-number">{day.getDate()}</span>
                  <span className="month-events">
                    {visibleItems.map((item) => {
                      const clock = compactClock(item.startsAt);
                      return (
                        <small
                          key={item.id}
                          title={item.shortTitle}
                          className={`projection-row ${item.source} owner-${item.ownerKind} ${
                            item.allDay ? 'all-day' : 'timed'
                          }`}
                        >
                          {clock && <span className="event-time">{clock}</span>}
                          <span className="event-title">{compactEventTitle(item)}</span>
                        </small>
                      );
                    })}
                    {hasTransport && (
                      <small className="transport-compact" aria-label="送り迎え担当">
                        {tokens.dropoff.token !== '—' && (
                          <span className="transport-part">
                            送
                            <b className={`transport-owner ${tokens.dropoff.tone}`}>
                              {tokens.dropoff.token}
                            </b>
                          </span>
                        )}
                        {tokens.pickup.token !== '—' && (
                          <span className="transport-part">
                            迎
                            <b className={`transport-owner ${tokens.pickup.tone}`}>
                              {tokens.pickup.token}
                            </b>
                          </span>
                        )}
                      </small>
                    )}
                    {hiddenCount > 0 && <small className="month-more">+{hiddenCount}</small>}
                  </span>
                </button>
              );
            })}
          </div>
          <section className="card day-detail">
            <h2>{selectedDateLabel(selected)}の予定</h2>
            {!selectedHasTransport && (projection.itemsByDate.get(selected) ?? []).length === 0 ? (
              <p className="empty-hint">予定はありません</p>
            ) : (
              <ul>
                {selectedHasTransport && (
                  <li className="day-transport-summary">
                    {selectedTokens.dropoff.token !== '—' && (
                      <span>
                        送<b className={`transport-owner ${selectedTokens.dropoff.tone}`}>{selectedTokens.dropoff.token}</b>
                      </span>
                    )}
                    {selectedTokens.pickup.token !== '—' && (
                      <span>
                        迎<b className={`transport-owner ${selectedTokens.pickup.tone}`}>{selectedTokens.pickup.token}</b>
                      </span>
                    )}
                  </li>
                )}
                {(projection.itemsByDate.get(selected) ?? []).map((item) => (
                  <li key={item.id}>
                    <button
                      type="button"
                      className="text-button calendar-detail-trigger"
                      onClick={() => setDetail(item)}
                    >
                      {item.fullTitle} <small>[{assigneeToken(item.ownerKind)}]</small>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </section>
          {detail && (
            <section className="card calendar-detail" aria-label="Google Calendar予定の詳細">
              <div className="section-heading">
                <h2>予定の詳細</h2>
                <button type="button" className="text-button" onClick={() => setDetail(null)}>
                  閉じる
                </button>
              </div>
              <strong>{detail.fullTitle}</strong>
              <p>
                開始: {detail.allDay ? `${detail.localDate}（終日）` : detail.startsAt ?? '—'}
              </p>
              <p>
                終了: {detail.allDay ? `${detail.localDate}（終日）` : detail.endsAt ?? '—'}
              </p>
              {detail.location && <p>場所: {detail.location}</p>}
              {detail.description && <p>説明: {detail.description}</p>}
              <p>
                出所: {detail.source === 'google' ? 'Google Calendar' : 'Family Ops'}
                {detail.sourceCalendar ? ` · ${detail.sourceCalendar}` : ''}
              </p>
            </section>
          )}
        </>
      )}
    </main>
  );
}

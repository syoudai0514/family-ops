import { useMemo, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { mamaUserId, papaUserId } from '../../lib/familyRoles';
import { TaskFormModal } from '../tasks/TaskFormModal';
import {
  buildCalendarProjection,
  transportCompactToken,
  transportLabel,
  type CalendarProjectionItem,
} from './calendarProjection';
import { localIsoDate } from './dateHelpers';
import { DayAgendaSheet } from './DayAgendaSheet';
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

export function monthDateHeading(date: string) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  if (!match) return '選択日の予定';
  return `${Number(match[2])}/${Number(match[3])} の予定`;
}

export function MonthView() {
  const { household, members } = useHousehold();
  const [anchor, setAnchor] = useState(() => new Date());
  const { start, end } = monthRange(anchor);
  const { tasks, occurrences, loading, error, refresh } = usePlanningData(
    household?.id ?? null,
    localIsoDate(start),
    localIsoDate(end),
  );
  const [selected, setSelected] = useState(localIsoDate(new Date()));
  const [sheetDate, setSheetDate] = useState<string | null>(null);
  const [taskFormDate, setTaskFormDate] = useState<string | null>(null);
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
  const selectedTransport = projection.transportByDate.get(selected);
  const selectedItems = projection.itemsByDate.get(selected) ?? [];
  const selectedMainTasks = tasks.filter(
    (task) =>
      task.scheduled_date === selected &&
      (task.status === 'todo' || task.status === 'in_progress') &&
      task.definition_code !== 'dropoff' &&
      task.definition_code !== 'pickup' &&
      task.category !== 'dropoff' &&
      task.category !== 'pickup',
  );

  const changeMonth = (delta: number) => {
    const next = new Date(anchor.getFullYear(), anchor.getMonth() + delta, 1);
    setAnchor(next);
    setSelected(localIsoDate(next));
    setSheetDate(null);
    setTaskFormDate(null);
  };

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
          <p className="month-contract-hint">日を選ぶと、予定・送迎・やることをカレンダーの下で確認できます。</p>
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
              const compactTransport = transportCompactToken(transport, primaryUserId, partnerUserId);
              const hasTransport = compactTransport.length > 0;
              const visibleItemLimit = hasTransport ? 2 : 3;
              const visibleItems = dayItems.slice(0, visibleItemLimit);
              const hiddenCount = Math.max(0, dayItems.length - visibleItems.length);
              const dayOfWeek = day.getDay();

              return (
                <button
                  key={date}
                  type="button"
                  onClick={() => setSelected(date)}
                  aria-pressed={selected === date}
                  aria-label={`${date}を選択`}
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
                      <small className="transport-compact" aria-label={`送迎 ${compactTransport}`}>
                        {compactTransport}
                      </small>
                    )}
                    {hiddenCount > 0 && <small className="month-more">+{hiddenCount}</small>}
                  </span>
                </button>
              );
            })}
          </div>

          <section className="card month-inline-agenda" aria-live="polite" data-selected-date={selected}>
            <div className="month-inline-heading">
              <div>
                <p className="eyebrow">選択中</p>
                <h2>{monthDateHeading(selected)}</h2>
              </div>
              {transportCompactToken(selectedTransport, primaryUserId, partnerUserId) && (
                <strong className="month-inline-transport-token">
                  {transportCompactToken(selectedTransport, primaryUserId, partnerUserId)}
                </strong>
              )}
            </div>
            <div className="month-inline-groups">
              <div>
                <h3>予定</h3>
                {selectedItems.length > 0 ? (
                  <ul className="month-inline-list">
                    {selectedItems.slice(0, 4).map((item) => (
                      <li key={item.id}>{item.fullTitle}</li>
                    ))}
                  </ul>
                ) : (
                  <p className="empty-hint">予定はありません。</p>
                )}
              </div>
              <div>
                <h3>送迎</h3>
                <p className="month-inline-detail">
                  {transportLabel(selectedTransport, primaryUserId, partnerUserId) ?? '送迎はありません。'}
                </p>
              </div>
              <div>
                <h3>主なToDo・準備</h3>
                {selectedMainTasks.length > 0 ? (
                  <ul className="month-inline-list">
                    {selectedMainTasks.slice(0, 4).map((task) => (
                      <li key={task.id}>{task.title}</li>
                    ))}
                  </ul>
                ) : (
                  <p className="empty-hint">やることはありません。</p>
                )}
              </div>
            </div>
            <div className="month-inline-actions">
              <button type="button" className="secondary-button" onClick={() => setSheetDate(selected)}>
                詳しく見る・編集
              </button>
              <button type="button" onClick={() => setTaskFormDate(selected)}>
                この日に追加
              </button>
            </div>
          </section>
        </>
      )}

      {sheetDate && (
        <DayAgendaSheet
          date={sheetDate}
          onClose={() => setSheetDate(null)}
          onChanged={refresh}
        />
      )}
      {taskFormDate && (
        <TaskFormModal
          mode="create"
          initialScheduledDate={taskFormDate}
          onClose={() => setTaskFormDate(null)}
          onSaved={() => {
            setTaskFormDate(null);
            void refresh();
          }}
        />
      )}
    </main>
  );
}

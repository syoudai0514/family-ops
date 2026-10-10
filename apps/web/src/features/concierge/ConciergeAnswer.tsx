import { useNavigate } from 'react-router-dom';
import { useHousehold } from '../../app/HouseholdContext';
import { usePlanningData } from '../planning/usePlanningData';
import { readOnlyDestination, type ConciergeProposal } from './conciergeFlow';
import { tokyoIsoDate } from '../planning/dateHelpers';

export function ConciergeAnswer({
  intent,
  draft,
}: {
  intent: NonNullable<ConciergeProposal['read_only_intent']>;
  draft: string;
}) {
  const navigate = useNavigate();
  const { household, members } = useHousehold();
  const start = tokyoIsoDate(new Date(Date.now() + (intent === 'tomorrow' ? 86400000 : 0)));
  const end = intent === 'week' ? tokyoIsoDate(new Date(Date.now() + 6 * 86400000)) : start;
  const showSchedule = ['today', 'tomorrow', 'week'].includes(intent);
  const planning = usePlanningData(showSchedule ? (household?.id ?? null) : null, start, end);
  const title =
    intent === 'tomorrow'
      ? '明日の予定・担当'
      : intent === 'week'
        ? 'これから7日間の予定・担当'
        : '今日の予定・担当';
  return (
    <div className="app-shell concierge-page">
      <button className="text-button" onClick={() => navigate(-1)}>
        ‹ 戻る
      </button>
      <h1>{showSchedule ? title : '必要な画面を開く'}</h1>
      <p className="task-item-meta">{draft}</p>
      {showSchedule && (
        <section className="card">
          <strong>
            {start}
            {end !== start ? ` 〜 ${end}` : ''}
          </strong>
          {planning.loading ? (
            <p role="status">予定を確認中…</p>
          ) : planning.error ? (
            <p role="alert">
              予定を取得できませんでした。予定なしとは限りません。詳細画面で再確認してください。
            </p>
          ) : (
            <>
              <ul className="today-schedule-list">
                {planning.tasks
                  .filter(
                    (task) =>
                      task.scheduled_date >= start &&
                      task.scheduled_date <= end &&
                      task.status !== 'cancelled',
                  )
                  .map((task) => (
                    <li key={task.id}>
                      {end !== start && `${task.scheduled_date} `}
                      {task.due_at &&
                        `${new Intl.DateTimeFormat('ja-JP', { timeZone: 'Asia/Tokyo', hour: '2-digit', minute: '2-digit' }).format(new Date(task.due_at))} `}
                      {task.title} ·{' '}
                      {members.find((member) => member.user_id === task.planned_assignee_id)
                        ?.profile?.display_name ??
                        (task.assignment_mode === 'anyone' ? '誰でもOK' : '担当未定')}
                    </li>
                  ))}
                {planning.occurrences.map((event) => (
                  <li key={event.id}>
                    {event.title ?? '予定'}
                    {event.time &&
                      ` · ${new Intl.DateTimeFormat('ja-JP', { timeZone: 'Asia/Tokyo', month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(event.time))}`}
                  </li>
                ))}
              </ul>
              {planning.tasks.length === 0 && planning.occurrences.length === 0 && (
                <p>登録されている予定・やることはありません。</p>
              )}
            </>
          )}
        </section>
      )}
      <button onClick={() => navigate(readOnlyDestination(intent))}>
        {showSchedule
          ? intent === 'week'
            ? '週の詳細を開く'
            : 'この日の詳細を開く'
          : intent === 'input'
            ? '朝・夜の記録を開く'
            : '内容を見る'}
      </button>
      <p className="task-item-meta">登録・送信はしていません。</p>
    </div>
  );
}

import { useMemo } from 'react';
import { formatTimeJa } from '../../lib/date';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import type { TodaySchedule as TodayScheduleData } from '../../lib/types';

// WP-DD6: server_tx_get_today_schedule now adapts the shared DailyBrief. Timed
// assignment conflicts are still annotated server-side. Google all-day entries
// arrive with starts_at=null plus their date range and are rendered as 終日 —
// never as a fake 00:00 timestamp and never as a timed conflict.
interface TodayScheduleProps {
  loading: boolean;
  error: string | null;
  schedule: TodayScheduleData | null;
  members: HouseholdMemberWithProfile[];
}

function displayNameFor(members: HouseholdMemberWithProfile[], userId: string | null): string {
  if (!userId) return '未割り当て';
  return members.find((m) => m.user_id === userId)?.profile?.display_name ?? '不明';
}

type ScheduleLine = { key: string; sortTime: string; text: string; conflict: boolean };

export function TodaySchedule({ loading, error, schedule, members }: TodayScheduleProps) {
  const lines = useMemo<ScheduleLine[]>(() => {
    if (!schedule) return [];
    const assignmentLines: ScheduleLine[] = schedule.assignments.map((a) => ({
      key: `assignment:${a.task_instance_id}`,
      sortTime: a.due_at,
      text: `${formatTimeJa(a.due_at)} ${a.title}（担当: ${displayNameFor(members, a.planned_assignee_id)}）`,
      conflict: a.has_conflict,
    }));
    const occurrenceLines: ScheduleLine[] = schedule.occurrences.map((occ) => {
      const busyNames = occ.busy_user_ids.map((id) => displayNameFor(members, id)).join('・');
      const suffix = busyNames.length > 0 ? `${busyNames}予定あり` : (occ.title ?? '(無題の予定)');
      const allDay = Boolean(occ.is_all_day) || !occ.starts_at;
      return {
        key: `occurrence:${occ.occurrence_key}`,
        sortTime: allDay ? '' : (occ.starts_at ?? ''),
        text: allDay ? `終日 ${suffix}` : `${formatTimeJa(occ.starts_at!)} ${suffix}`,
        conflict: false,
      };
    });
    return [...assignmentLines, ...occurrenceLines].sort((a, b) =>
      a.sortTime.localeCompare(b.sortTime),
    );
  }, [schedule, members]);

  if (loading) return null;
  if (!error && lines.length === 0 && schedule?.calendar_connected && !schedule.calendar_stale) {
    return null;
  }

  return (
    <section className="card">
      <h2>今/次の予定</h2>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      {schedule && !schedule.calendar_connected && (
        <p className="empty-hint">
          Googleカレンダーは未接続です。家事の予定は引き続き利用できます。
        </p>
      )}
      {schedule?.calendar_stale && (
        <p role="alert" className="error-text">
          ⚠ Google予定を最新化できていません
        </p>
      )}
      {lines.length > 0 && (
        <ul className="today-schedule-list">
          {lines.map((line) => (
            <li key={line.key}>
              {line.text}
              {line.conflict && <span className="error-text"> ⚠ 予定と重複</span>}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

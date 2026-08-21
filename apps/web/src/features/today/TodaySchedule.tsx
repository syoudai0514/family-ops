import { useMemo } from 'react';
import { formatTimeJa } from '../../lib/date';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import type { TodaySchedule as TodayScheduleData } from '../../lib/types';

// Sol re-review #3 fix (P1-2, docs/adr/0011): Today Priority 1's "今/次の予定"
// (docs/design/v6/02_UX_AND_SCREENS.md #3):
//   `17:30 お迎え（担当: ママ）`
//   `18:00 ママ予定あり ⚠ お迎えと重複`
// Every occurrence/assignment here is already filtered and conflict-
// annotated by server_tx_get_today_schedule — this component performs zero
// calendar-domain computation of its own, only rendering + merging the two
// arrays into one chronological list (a task line's own "予定あり" conflict
// note references the calendar side, but the two are never rendered as
// duplicate lines for the same logical event since they come from
// disjoint tables with no natural 1:1 key between them).
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
      return {
        key: `occurrence:${occ.occurrence_key}`,
        sortTime: occ.starts_at,
        text: `${formatTimeJa(occ.starts_at)} ${suffix}`,
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

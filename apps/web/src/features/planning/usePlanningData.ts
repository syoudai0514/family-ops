import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../../lib/supabaseClient';
import { addDays, tokyoIsoDate } from './dateHelpers';
import type { GooglePlanningOccurrence, PlanningTask } from './calendarProjection';

export function usePlanningData(householdId: string | null, start: string, end: string) {
  const [tasks, setTasks] = useState<PlanningTask[]>([]);
  const [occurrences, setOccurrences] = useState<GooglePlanningOccurrence[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!householdId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const nextDay = tokyoIsoDate(addDays(new Date(`${end}T00:00:00+09:00`), 1));
      const [{ data: taskRows, error: taskError }, { data: timedCalendarRows, error: timedCalendarError }, { data: allDayCalendarRows, error: allDayCalendarError }] =
        await Promise.all([
          supabase
            .from('task_instances')
            .select('*, task_definitions(code, calendar_visibility)')
            .eq('household_id', householdId)
            .gte('scheduled_date', start)
            .lte('scheduled_date', end)
            .neq('status', 'cancelled')
            .order('scheduled_date'),
          supabase
            .from('calendar_event_occurrences')
            .select('*, calendar_connections(display_name,external_calendar_id)')
            .eq('household_id', householdId)
            .gte('starts_at', `${start}T00:00:00+09:00`)
            .lt('starts_at', `${nextDay}T00:00:00+09:00`)
            .order('starts_at'),
          supabase
            .from('calendar_event_occurrences')
            .select('*, calendar_connections(display_name,external_calendar_id)')
            .eq('household_id', householdId)
            // all_day_end_exclusive is an exclusive local date. This is the
            // standard interval-overlap predicate, so events that began
            // before the visible range still appear on every covered day.
            .lte('all_day_start', end)
            .gt('all_day_end_exclusive', start)
            .order('all_day_start'),
        ]);
      if (taskError) throw taskError;
      // Calendar is optional (for households that have not connected Google).
      const calendarError = timedCalendarError ?? allDayCalendarError;
      if (calendarError && !/does not exist|permission/i.test(calendarError.message)) throw calendarError;
      setTasks(
        (taskRows ?? []).map((row: Record<string, unknown>) => {
          const definition = row.task_definitions as { code?: string; calendar_visibility?: PlanningTask['calendar_visibility'] } | null;
          return {
            ...row,
            definition_code: definition?.code ?? null,
            calendar_visibility: (row.calendar_visibility as PlanningTask['calendar_visibility']) ?? definition?.calendar_visibility ?? null,
          } as PlanningTask;
        }),
      );
      setOccurrences(
        [...(timedCalendarRows ?? []), ...(allDayCalendarRows ?? [])].map((row: Record<string, unknown>) => {
          const startsAt = typeof row.starts_at === 'string' ? row.starts_at : null;
          const endsAt = typeof row.ends_at === 'string' ? row.ends_at : null;
          const allDayStart = typeof row.all_day_start === 'string' ? row.all_day_start : null;
          const allDayEndExclusive = typeof row.all_day_end_exclusive === 'string' ? row.all_day_end_exclusive : null;
          const connection = row.calendar_connections as { display_name?: string; external_calendar_id?: string } | null;
          return {
            id: String(row.occurrence_key),
            date: allDayStart ?? (startsAt ? tokyoIsoDate(startsAt) : start),
            time: startsAt,
            endsAt,
            title: typeof row.title === 'string' && row.title ? row.title : '予定',
            allDay: Boolean(allDayStart),
            allDayEndExclusive,
            transparent: row.transparency === 'transparent',
            ownerUserId: typeof row.creator_mapped_user_id === 'string' ? row.creator_mapped_user_id : null,
            providerEventId: typeof row.google_event_id === 'string' ? row.google_event_id : null,
            generatedByFamilyOps: row.family_ops_mirror === true,
            hasConflict: false,
            location: typeof row.location === 'string' && row.location ? row.location : null,
            description: typeof row.description === 'string' && row.description ? row.description : null,
            sourceCalendar: connection?.display_name ?? connection?.external_calendar_id ?? null,
          };
        }),
      );
    } catch (err) {
      setError(err instanceof Error ? err.message : '予定を読み込めませんでした。');
    } finally {
      setLoading(false);
    }
  }, [end, householdId, start]);

  useEffect(() => {
    load();
  }, [load]);
  return { loading, error, tasks, occurrences, refresh: load };
}

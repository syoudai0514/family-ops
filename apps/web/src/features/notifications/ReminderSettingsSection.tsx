import { useEffect, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { supabase } from '../../lib/supabaseClient';
import {
  ALL_DAY_REMINDER_OPTIONS,
  defaultReminders,
  MAX_REMINDERS,
  reminderLabel,
  TIMED_REMINDER_OPTIONS,
} from '../planning/scheduleDetails';

type Settings = {
  default_timed_reminders?: number[];
  default_all_day_reminders?: number[];
  schedule_line_with_push?: boolean;
};

async function saveSettings(settings: Settings) {
  await callEdgeFunction(EDGE_FUNCTIONS.updateNotificationPreferences, {
    operation_id: newOperationId(),
    reminder_settings: settings,
  });
}

function ReminderDefaultPicker({
  legend,
  options,
  allDay,
  value,
  disabled,
  onChange,
}: {
  legend: string;
  options: number[];
  allDay: boolean;
  value: number[];
  disabled: boolean;
  onChange: (next: number[]) => void;
}) {
  return (
    <fieldset className="reminder-picker">
      <legend>{legend}</legend>
      <div className="reminder-options">
        {options.map((minutes) => {
          const checked = value.includes(minutes);
          return (
            <label key={minutes} className="reminder-chip">
              <input
                type="checkbox"
                checked={checked}
                disabled={disabled || (!checked && value.length >= MAX_REMINDERS)}
                onChange={(e) =>
                  onChange(
                    (e.target.checked ? [...value, minutes] : value.filter((item) => item !== minutes)).sort(
                      (a, b) => a - b,
                    ),
                  )
                }
              />
              {reminderLabel(minutes, allDay)}
            </label>
          );
        })}
      </div>
      {value.length === 0 && <p className="form-help">新しい予定には通知を付けません。</p>}
    </fieldset>
  );
}

/** How new 予定 are reminded: the family's defaults and, per person, whether LINE also rings. */
export function ReminderSettingsSection() {
  const { household, me, refresh } = useHousehold();
  const [lineWithPush, setLineWithPush] = useState<boolean | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  const householdId = household?.id ?? null;
  const userId = me?.user_id ?? null;

  useEffect(() => {
    if (!householdId || !userId) return;
    let cancelled = false;
    void Promise.resolve(
      supabase
        .from('notification_preferences')
        .select('schedule_line_with_push')
        .eq('household_id', householdId)
        .eq('user_id', userId)
        .maybeSingle(),
    )
      .then(({ data }) => {
        if (!cancelled) setLineWithPush(Boolean((data as { schedule_line_with_push?: boolean } | null)?.schedule_line_with_push));
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [householdId, userId]);

  async function save(settings: Settings, message: string) {
    setSaving(true);
    setError(null);
    setSaved(null);
    try {
      await saveSettings(settings);
      if ('schedule_line_with_push' in settings) setLineWithPush(Boolean(settings.schedule_line_with_push));
      else await refresh();
      setSaved(message);
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '保存できませんでした。もう一度お試しください。');
    } finally {
      setSaving(false);
    }
  }

  const timed = defaultReminders(true, household);
  const allDay = defaultReminders(false, household);
  return (
    <section className="card">
      <h2>予定の通知</h2>
      <p className="form-help">
        新しく作る予定に最初から付く通知です（LINEや「＋」の文章入力で作った予定も同じです）。家族で共通の設定です。予定ごとに変えることもできます。
      </p>
      <ReminderDefaultPicker
        legend="時刻のある予定"
        options={TIMED_REMINDER_OPTIONS}
        allDay={false}
        value={timed}
        disabled={saving}
        onChange={(next) => void save({ default_timed_reminders: next }, '時刻のある予定の通知を保存しました。')}
      />
      <ReminderDefaultPicker
        legend="終日の予定"
        options={ALL_DAY_REMINDER_OPTIONS}
        allDay
        value={allDay}
        disabled={saving}
        onChange={(next) => void save({ default_all_day_reminders: next }, '終日の予定の通知を保存しました。')}
      />
      {lineWithPush !== null && (
        <label className="checkbox-row">
          <input
            type="checkbox"
            checked={lineWithPush}
            disabled={saving}
            onChange={(e) =>
              void save(
                { schedule_line_with_push: e.target.checked },
                e.target.checked
                  ? 'スマホの通知に加えて、LINEでも受け取ります。'
                  : '通知をオンにした端末がある時は、LINEでは送りません。',
              )
            }
          />
          スマホの通知をオンにしていても、予定の通知をLINEでも受け取る（自分だけの設定。LINEの無料枠を使います）
        </label>
      )}
      {saved && <p role="status">{saved}</p>}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </section>
  );
}

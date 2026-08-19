import { useCallback, useEffect, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { InviteSection } from '../household/InviteSection';
import { ROUTINE_SCHEDULE_KINDS, type HouseholdRoutineSchedule, type RoutineScheduleKind } from '../../lib/types';

const SCHEDULE_LABELS: Record<RoutineScheduleKind, string> = {
  daily_assignment: '今日の担当のお知らせ',
  dropoff_checklist: '送りチェックリスト',
  dropoff_checkin: '送りの確認',
  pickup_checklist: 'お迎えチェックリスト',
  pickup_checkin: 'お迎えの確認',
  nonpickup_evening_checklist: '夜の家事チェックリスト',
  nonpickup_evening_checkin: '夜の家事の確認',
  nonworkday_morning_digest: '休日の朝まとめ',
  nonworkday_checkin: '休日の確認',
};

const DEFAULT_TIME = '19:00';

interface RowState {
  enabled: boolean;
  localTime: string;
  dirty: boolean;
}

function useRoutineSchedules(householdId: string | null) {
  const [rows, setRows] = useState<Map<RoutineScheduleKind, HouseholdRoutineSchedule>>(new Map());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!householdId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    const { data, error: fetchError } = await supabase
      .from('household_routine_schedules')
      .select('*')
      .eq('household_id', householdId);
    if (fetchError) setError(fetchError.message);
    else setRows(new Map((data ?? []).map((r) => [r.schedule_kind, r])));
    setLoading(false);
  }, [householdId]);

  useEffect(() => {
    load();
  }, [load]);

  return { rows, loading, error, refresh: load };
}

export function RoutineSchedule() {
  const { household } = useHousehold();
  const { rows, loading, error, refresh } = useRoutineSchedules(household?.id ?? null);
  const [draft, setDraft] = useState<Record<RoutineScheduleKind, RowState>>(
    {} as Record<RoutineScheduleKind, RowState>,
  );
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [savedMessage, setSavedMessage] = useState<string | null>(null);

  useEffect(() => {
    const next = {} as Record<RoutineScheduleKind, RowState>;
    for (const kind of ROUTINE_SCHEDULE_KINDS) {
      const existing = rows.get(kind);
      next[kind] = {
        enabled: existing?.enabled ?? false,
        localTime: existing?.local_time ?? DEFAULT_TIME,
        dirty: false,
      };
    }
    setDraft(next);
  }, [rows]);

  function updateDraft(kind: RoutineScheduleKind, patch: Partial<RowState>) {
    setDraft((prev) => ({ ...prev, [kind]: { ...prev[kind], ...patch, dirty: true } }));
  }

  // update-routine-schedule takes one schedule_kind per call. Each call is
  // independently idempotent (operation_id per row), so sequential calls for
  // just the rows the user touched is simplest and correct — no need to
  // batch client-side.
  async function handleSave() {
    setSaving(true);
    setSaveError(null);
    setSavedMessage(null);
    try {
      const dirtyKinds = ROUTINE_SCHEDULE_KINDS.filter((kind) => draft[kind]?.dirty);
      for (const kind of dirtyKinds) {
        const row = draft[kind];
        await callEdgeFunction(EDGE_FUNCTIONS.updateRoutineSchedule, {
          operation_id: newOperationId(),
          schedule_kind: kind,
          enabled: row.enabled,
          local_time: row.localTime,
        });
      }
      await refresh();
      setSavedMessage('保存しました。');
    } catch (err) {
      setSaveError(err instanceof FamilyOpsApiError ? err.message : '保存に失敗しました。');
    } finally {
      setSaving(false);
    }
  }

  const hasDirty = Object.values(draft).some((r) => r.dirty);

  return (
    <div className="app-shell">
      <h1>設定</h1>
      <InviteSection />
      <section className="card">
        <h2>ルーティンスケジュール</h2>
        {loading && <p role="status">読み込み中…</p>}
        {error && (
          <p role="alert" className="error-text">
            {error}
          </p>
        )}
        {!loading && (
          <ul className="routine-schedule-list">
            {ROUTINE_SCHEDULE_KINDS.map((kind) => {
              const row = draft[kind];
              if (!row) return null;
              return (
                <li key={kind} className="routine-schedule-row">
                  <label>
                    <input
                      type="checkbox"
                      checked={row.enabled}
                      onChange={(e) => updateDraft(kind, { enabled: e.target.checked })}
                    />
                    {SCHEDULE_LABELS[kind]}
                  </label>
                  <input
                    type="time"
                    value={row.localTime}
                    disabled={!row.enabled}
                    onChange={(e) => updateDraft(kind, { localTime: e.target.value })}
                    aria-label={`${SCHEDULE_LABELS[kind]}の時刻`}
                  />
                </li>
              );
            })}
          </ul>
        )}
        {saveError && (
          <p role="alert" className="error-text">
            {saveError}
          </p>
        )}
        {savedMessage && <p role="status">{savedMessage}</p>}
        <button type="button" onClick={handleSave} disabled={saving || !hasDirty}>
          {saving ? '保存中…' : '保存する'}
        </button>
      </section>
    </div>
  );
}

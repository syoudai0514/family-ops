import { useCallback, useEffect, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { InviteSection } from '../household/InviteSection';
import { ROUTINE_SCHEDULE_KINDS, type HouseholdRoutineSchedule, type RoutineScheduleKind } from '../../lib/types';
import { WEEKDAYS } from '../../lib/weekdays';

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
  const { household, members } = useHousehold();
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
      <h1>いつもの担当</h1>
      <p className="page-lead">毎週くり返す担当を変えます。今日だけの交代は、週の予定から相談してください。</p>
      <DropoffPickupMatrix householdId={household?.id ?? null} members={members} />
      <section className="card"><h2>夜の家事</h2><p className="empty-hint">夕食・お風呂・洗濯などの役割は、初期設定時に登録したルールで運用されます。変更は次の更新でこの画面にまとめます。</p></section>
      <section className="card"><h2>朝の準備</h2><p className="empty-hint">曜日ごとの持ち物は、今後ここから追加できます。</p></section>
      <section className="card">
        <h2>通知</h2>
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
      <details className="settings-details"><summary>家族の招待</summary><InviteSection /></details>
    </div>
  );
}

type MatrixRow = { id: string; code: 'dropoff' | 'pickup'; weekday: number; assigneeId: string; localTime: string };

function DropoffPickupMatrix({ householdId, members }: { householdId: string | null; members: ReturnType<typeof useHousehold>['members'] }) {
  const [rows, setRows] = useState<MatrixRow[]>([]); const [loading, setLoading] = useState(true); const [saving, setSaving] = useState<string | null>(null); const [error, setError] = useState<string | null>(null); const [notice, setNotice] = useState<string | null>(null);
  const load = useCallback(async () => { if (!householdId) { setLoading(false); return; } setLoading(true); setError(null); const [{ data: definitions, error: definitionError }, { data: rules, error: ruleError }] = await Promise.all([supabase.from('task_definitions').select('id, code').eq('household_id', householdId).in('code', ['dropoff', 'pickup']), supabase.from('recurrence_rules').select('task_definition_id, weekday, planned_assignee_id, scheduled_local_time').eq('household_id', householdId).eq('active', true).in('weekday', [1, 2, 3, 4, 5])]); if (definitionError || ruleError) { setError(definitionError?.message ?? ruleError?.message ?? '担当ルールを読み込めませんでした。'); setLoading(false); return; } const idByCode = new Map((definitions ?? []).map((row: { id: string; code: string }) => [row.code, row.id])); setRows(['dropoff', 'pickup'].flatMap((code) => WEEKDAYS.slice(0, 5).map(({ value: weekday }) => { const rule = (rules ?? []).find((item: { task_definition_id: string; weekday: number }) => item.task_definition_id === idByCode.get(code) && item.weekday === weekday) as { planned_assignee_id: string | null; scheduled_local_time: string | null } | undefined; return { id: idByCode.get(code) ?? '', code: code as 'dropoff' | 'pickup', weekday, assigneeId: rule?.planned_assignee_id ?? '', localTime: rule?.scheduled_local_time?.slice(0, 5) ?? (code === 'dropoff' ? '08:00' : '17:30') }; }))); setLoading(false); }, [householdId]);
  useEffect(() => { load(); }, [load]);
  const update = (code: MatrixRow['code'], weekday: number, patch: Partial<MatrixRow>) => setRows((current) => current.map((row) => row.code === code && row.weekday === weekday ? { ...row, ...patch } : row));
  const save = async (row: MatrixRow) => { if (!row.id) return; setError(null); setNotice(null); setSaving(`${row.code}-${row.weekday}`); try { await callEdgeFunction(EDGE_FUNCTIONS.changeRecurrence, { operation_id: newOperationId(), task_definition_id: row.id, weekday: row.weekday, assignee_strategy: row.assigneeId ? 'fixed' : 'unassigned', planned_assignee_user_id: row.assigneeId || undefined, scheduled_local_time: row.localTime || undefined, effective_from: new Date().toLocaleDateString('sv-SE') }); setNotice('これから毎回の担当を保存しました。'); await load(); } catch (err) { setError(err instanceof FamilyOpsApiError ? err.message : '保存に失敗しました。'); } finally { setSaving(null); } };
  return <section className="card routine-matrix-card"><div className="section-heading"><div><h2>送り・お迎え</h2><p className="empty-hint">曜日を押して、その場で保存できます。</p></div></div>{loading ? <p role="status">読み込み中…</p> : <div className="routine-matrix"><div className="matrix-head">担当</div>{WEEKDAYS.slice(0, 5).map((day) => <div className="matrix-head" key={day.value}>{day.label}</div>)}{(['dropoff', 'pickup'] as const).map((code) => <><div className="matrix-label" key={`${code}-label`}>{code === 'dropoff' ? '送り' : 'お迎え'}</div>{WEEKDAYS.slice(0, 5).map((day) => { const row = rows.find((item) => item.code === code && item.weekday === day.value); if (!row) return <div key={`${code}-${day.value}`} />; const key = `${code}-${day.value}`; return <div className="matrix-cell" key={key}><select aria-label={`${code === 'dropoff' ? '送り' : 'お迎え'} ${day.label}曜日の担当`} value={row.assigneeId} onChange={(event) => update(code, day.value, { assigneeId: event.target.value })}><option value="">なし</option>{members.map((member) => <option value={member.user_id} key={member.user_id}>{member.profile?.display_name ?? '家族'}</option>)}</select><input aria-label={`${day.label}曜日の時刻`} type="time" value={row.localTime} onChange={(event) => update(code, day.value, { localTime: event.target.value })} /><button type="button" className="matrix-save" onClick={() => save(row)} disabled={saving === key}>{saving === key ? '…' : '保存'}</button></div>; })}</>)}</div>}{error && <p role="alert" className="error-text">{error}</p>}{notice && <p role="status">{notice}</p>}</section>;
}

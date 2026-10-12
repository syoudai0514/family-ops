import { forwardRef, useCallback, useEffect, useImperativeHandle, useState } from 'react';
import { useLocation } from 'react-router-dom';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { InviteSection } from '../household/InviteSection';
import {
  ROUTINE_SCHEDULE_KINDS,
  type HouseholdRoutineSchedule,
  type RoutineScheduleKind,
} from '../../lib/types';
import { WEEKDAYS } from '../../lib/weekdays';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';

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

export function scrollToRoutineAnchor(hash: string, documentRef: Document = document) {
  const id = hash.replace(/^#/, '');
  if (id !== 'custom-routines' && id !== 'morning-preparation') return false;
  const target = documentRef.getElementById(id);
  if (!target) return false;
  target.scrollIntoView({ block: 'start' });
  if (target instanceof HTMLElement) target.focus({ preventScroll: true });
  return true;
}

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
  const location = useLocation();
  const { rows, loading, error, refresh } = useRoutineSchedules(household?.id ?? null);
  const [draft, setDraft] = useState<Record<RoutineScheduleKind, RowState>>(
    {} as Record<RoutineScheduleKind, RowState>,
  );
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [savedMessage, setSavedMessage] = useState<string | null>(null);

  useEffect(() => {
    const cancel = requestAnimationFrame(() => {
      scrollToRoutineAnchor(location.hash);
    });
    return () => cancelAnimationFrame(cancel);
  }, [location.hash]);

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
      <DropoffPickupMatrix householdId={household?.id ?? null} members={members} />
      <section className="card" id="routine-notifications">
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
      <details className="settings-details">
        <summary>家族の招待</summary>
        <InviteSection />
      </details>
    </div>
  );
}

type EditableRule = {
  id: string;
  code: string;
  title: string;
  enabled: boolean;
  weekdays: number[];
  strategy: 'dropoff_assignee' | 'pickup_assignee' | 'nonpickup_adult' | 'fixed';
  fixedAssigneeId: string;
  fallbackAssigneeId: string;
  localTime: string;
  taskCode?: string;
  originalWeekdays?: number[];
};

function weekdayChecks(row: EditableRule, onToggle: (weekday: number) => void) {
  return (
    <div className="weekday-picker" aria-label={`${row.title}の曜日`}>
      {WEEKDAYS.map((day) => (
        <label className="weekday-chip" key={day.value}>
          <input
            type="checkbox"
            checked={row.weekdays.includes(day.value)}
            onChange={() => onToggle(day.value)}
          />
          {day.label}
        </label>
      ))}
    </div>
  );
}

export interface MorningPreparationEditorHandle {
  saveAll: () => Promise<boolean>;
}

export const MorningPreparationEditor = forwardRef<MorningPreparationEditorHandle, {
  householdId: string | null;
  members: HouseholdMemberWithProfile[];
}>(function MorningPreparationEditor({
  householdId,
  members,
}, ref) {
  const [rows, setRows] = useState<EditableRule[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [newTitle, setNewTitle] = useState('');
  const [newDays, setNewDays] = useState<number[]>([]);
  const load = useCallback(async () => {
    if (!householdId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    const [{ data: definitions, error: definitionError }, { data: rules, error: ruleError }] =
      await Promise.all([
        supabase
          .from('task_definitions')
          .select('id, code, title')
          .eq('household_id', householdId)
          .eq('routine_phase', 'morning')
          .eq('is_active', true),
        supabase
          .from('recurrence_rules')
          .select(
            'task_definition_id, weekday, assignee_strategy, planned_assignee_id, fallback_assignee_id, scheduled_local_time',
          )
          .eq('household_id', householdId)
          .eq('active', true),
      ]);
    if (definitionError || ruleError) {
      setError(
        definitionError?.message ?? ruleError?.message ?? '朝の準備を読み込めませんでした。',
      );
      setLoading(false);
      return;
    }
    const nextRows: EditableRule[] = (definitions ?? [])
      .filter((definition: { code: string }) => definition.code !== 'dropoff')
      .map((definition: { id: string; code: string; title: string }) => {
        const matched = (rules ?? []).filter(
          (rule: { task_definition_id: string }) => rule.task_definition_id === definition.id,
        ) as Array<{
          weekday: number;
          assignee_strategy: EditableRule['strategy'];
          planned_assignee_id: string | null;
          fallback_assignee_id: string | null;
          scheduled_local_time: string | null;
        }>;
        const first = matched[0];
        return {
          id: definition.id,
          code: definition.code,
          title: definition.title,
          enabled: true,
          weekdays: matched.map((rule) => rule.weekday),
          strategy: first?.assignee_strategy === 'fixed' ? 'fixed' : 'dropoff_assignee',
          fixedAssigneeId: first?.planned_assignee_id ?? '',
          fallbackAssigneeId: first?.fallback_assignee_id ?? '',
          localTime: first?.scheduled_local_time?.slice(0, 5) ?? '07:00',
        };
      });
    setRows(nextRows);
    setLoading(false);
  }, [householdId]);
  useEffect(() => {
    load();
  }, [load]);
  const saveRow = async (row: EditableRule) => {
    setSaving(row.id);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.editTaskDefinition, {
        operation_id: newOperationId(),
        task_definition_id: row.id,
        title: row.title,
        routine_phase: 'morning',
      });
      await callEdgeFunction(EDGE_FUNCTIONS.replaceRecurrenceSchedule, {
        operation_id: newOperationId(),
        replacements: [
          {
            task_definition_id: row.id,
            rules: row.weekdays.map((weekday) => ({
              weekday,
              assignee_strategy: row.strategy,
              planned_assignee_user_id: row.strategy === 'fixed'
                ? row.fixedAssigneeId
                : row.fallbackAssigneeId || undefined,
              scheduled_local_time: row.localTime,
            })),
          },
        ],
      });
      await load();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '朝の準備を保存できませんでした。');
    } finally {
      setSaving(null);
    }
  };
  const add = async () => {
    if (!newTitle.trim() || newDays.length === 0) {
      setError('持ち物と曜日を入力してください。');
      return;
    }
    setSaving('new');
    setError(null);
    try {
      const created = await callEdgeFunction<{ task_definition_id: string }>(
        EDGE_FUNCTIONS.createTaskDefinition,
        {
          operation_id: newOperationId(),
          code: `prep_custom_${Date.now()}`,
          title: newTitle.trim(),
          category: 'preparation',
          routine_phase: 'morning',
          completion_mode: 'whole',
        },
      );
      await callEdgeFunction(EDGE_FUNCTIONS.replaceRecurrenceSchedule, {
        operation_id: newOperationId(),
        replacements: [
          {
            task_definition_id: created.task_definition_id,
            rules: newDays.map((weekday) => ({
              weekday,
              assignee_strategy: 'dropoff_assignee',
              scheduled_local_time: '07:00',
            })),
          },
        ],
      });
      setNewTitle('');
      setNewDays([]);
      await load();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '持ち物を追加できませんでした。');
    } finally {
      setSaving(null);
    }
  };
  const saveAll = useCallback(async (): Promise<boolean> => {
    if (rows.some((row) => row.strategy === 'fixed' && !row.fixedAssigneeId)) {
      setError('固定の担当を選択してください。');
      return false;
    }
    setSaving('all');
    setError(null);
    try {
      // Definitions and all weekday rules are committed before onboarding
      // progresses. One schedule replacement preserves a full weekly edit.
      for (const row of rows) {
        await callEdgeFunction(EDGE_FUNCTIONS.editTaskDefinition, {
          operation_id: newOperationId(),
          task_definition_id: row.id,
          title: row.title,
          routine_phase: 'morning',
        });
      }
      await callEdgeFunction(EDGE_FUNCTIONS.replaceRecurrenceSchedule, {
        operation_id: newOperationId(),
        replacements: rows.map((row) => ({
          task_definition_id: row.id,
          rules: row.weekdays.map((weekday) => ({
            weekday,
            assignee_strategy: row.strategy,
            planned_assignee_user_id: row.strategy === 'fixed'
                ? row.fixedAssigneeId
                : row.fallbackAssigneeId || undefined,
            scheduled_local_time: row.localTime,
          })),
        })),
      });
      await load();
      return true;
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '朝の準備を保存できませんでした。');
      return false;
    } finally {
      setSaving(null);
    }
  }, [load, rows]);
  useImperativeHandle(ref, () => ({ saveAll }), [saveAll]);
  return (
    <section id="morning-preparation" className="card routine-editor">
      <div className="section-heading">
        <div>
          <h2>朝の準備・曜日持ち物</h2>
          <p className="empty-hint">朝のLINEチェックリストに反映される、曜日ごとの持ち物です。</p>
        </div>
      </div>
      {loading ? (
        <p role="status">読み込み中…</p>
      ) : (
        <div className="routine-rule-list">
          {rows.map((row) => (
            <article className="routine-rule" key={row.id}>
              <label>
                持ち物・準備
                <input
                  value={row.title}
                  onChange={(event) =>
                    setRows((current) =>
                      current.map((item) =>
                        item.id === row.id ? { ...item, title: event.target.value } : item,
                      ),
                    )
                  }
                />
              </label>
              <div className="routine-rule-top">
                <label>
                  担当
                  <select
                    value={row.strategy}
                    onChange={(event) =>
                      setRows((current) =>
                        current.map((item) =>
                          item.id === row.id
                            ? { ...item, strategy: event.target.value as EditableRule['strategy'] }
                            : item,
                        ),
                      )
                    }
                  >
                    <option value="dropoff_assignee">送り担当</option>
                    <option value="fixed">固定する</option>
                  </select>
                </label>
                <input
                  type="time"
                  value={row.localTime}
                  aria-label={`${row.title}の時刻`}
                  onChange={(event) =>
                    setRows((current) =>
                      current.map((item) =>
                        item.id === row.id ? { ...item, localTime: event.target.value } : item,
                      ),
                    )
                  }
                />
              </div>
              {row.strategy === 'fixed' && (
                <label>
                  固定の担当
                  <select
                    value={row.fixedAssigneeId}
                    onChange={(event) =>
                      setRows((current) =>
                        current.map((item) =>
                          item.id === row.id
                            ? { ...item, fixedAssigneeId: event.target.value }
                            : item,
                        ),
                      )
                    }
                  >
                    <option value="">選択してください</option>
                    {members.map((member) => (
                      <option key={member.user_id} value={member.user_id}>
                        {member.profile?.display_name ?? '家族'}
                      </option>
                    ))}
                  </select>
                </label>
              )}
              {row.strategy !== 'fixed' && (
                <label>
                  平日に送迎がない日の担当（任意）
                  <select
                    value={row.fallbackAssigneeId}
                    onChange={(event) =>
                      setRows((current) =>
                        current.map((item) =>
                          item.id === row.id
                            ? { ...item, fallbackAssigneeId: event.target.value }
                            : item,
                        ),
                      )
                    }
                  >
                    <option value="">未設定のまま</option>
                    {members.map((member) => (
                      <option key={member.user_id} value={member.user_id}>
                        {member.profile?.display_name ?? '家族'}
                      </option>
                    ))}
                  </select>
                  <small className="empty-hint">土日は送りがなければ「誰でもOK」になります。平日に送り担当がいない場合だけ使います。</small>
                </label>
              )}
              {weekdayChecks(row, (weekday) =>
                setRows((current) =>
                  current.map((item) =>
                    item.id === row.id
                      ? {
                          ...item,
                          weekdays: item.weekdays.includes(weekday)
                            ? item.weekdays.filter((day) => day !== weekday)
                            : [...item.weekdays, weekday],
                        }
                      : item,
                  ),
                ),
              )}
              <button
                type="button"
                className="secondary-button"
                onClick={() => saveRow(row)}
                disabled={saving === row.id}
              >
                {saving === row.id ? '保存中…' : 'これから毎回に保存'}
              </button>
            </article>
          ))}
        </div>
      )}
      <div className="add-preparation">
        <h3>持ち物を追加</h3>
        <input
          value={newTitle}
          onChange={(event) => setNewTitle(event.target.value)}
          placeholder="例: 水筒"
          aria-label="追加する持ち物"
        />
        <div className="weekday-picker">
          {WEEKDAYS.map((day) => (
            <label className="weekday-chip" key={day.value}>
              <input
                type="checkbox"
                checked={newDays.includes(day.value)}
                onChange={() =>
                  setNewDays((current) =>
                    current.includes(day.value)
                      ? current.filter((item) => item !== day.value)
                      : [...current, day.value],
                  )
                }
              />
              {day.label}
            </label>
          ))}
        </div>
        <button type="button" onClick={add} disabled={saving === 'new'}>
          {saving === 'new' ? '追加中…' : '朝の準備に追加'}
        </button>
      </div>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </section>
  );
});

type MatrixRow = {
  id: string;
  code: 'dropoff' | 'pickup';
  weekday: number;
  assigneeId: string;
  localTime: string;
};

function DropoffPickupMatrix({
  householdId,
  members,
}: {
  householdId: string | null;
  members: ReturnType<typeof useHousehold>['members'];
}) {
  const [rows, setRows] = useState<MatrixRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const load = useCallback(async () => {
    if (!householdId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    const [{ data: definitions, error: definitionError }, { data: rules, error: ruleError }] =
      await Promise.all([
        supabase
          .from('task_definitions')
          .select('id, code')
          .eq('household_id', householdId)
          .in('code', ['dropoff', 'pickup']),
        supabase
          .from('recurrence_rules')
          .select('task_definition_id, weekday, planned_assignee_id, scheduled_local_time')
          .eq('household_id', householdId)
          .eq('active', true)
          .in('weekday', [1, 2, 3, 4, 5, 6, 7]),
      ]);
    if (definitionError || ruleError) {
      setError(
        definitionError?.message ?? ruleError?.message ?? '担当ルールを読み込めませんでした。',
      );
      setLoading(false);
      return;
    }
    const idByCode = new Map(
      (definitions ?? []).map((row: { id: string; code: string }) => [row.code, row.id]),
    );
    setRows(
      ['dropoff', 'pickup'].flatMap((code) =>
        WEEKDAYS.map(({ value: weekday }) => {
          const rule = (rules ?? []).find(
            (item: { task_definition_id: string; weekday: number }) =>
              item.task_definition_id === idByCode.get(code) && item.weekday === weekday,
          ) as
            { planned_assignee_id: string | null; scheduled_local_time: string | null } | undefined;
          return {
            id: idByCode.get(code) ?? '',
            code: code as 'dropoff' | 'pickup',
            weekday,
            assigneeId: rule?.planned_assignee_id ?? '',
            localTime:
              rule?.scheduled_local_time?.slice(0, 5) ?? (code === 'dropoff' ? '08:00' : '17:30'),
          };
        }),
      ),
    );
    setLoading(false);
  }, [householdId]);
  useEffect(() => {
    load();
  }, [load]);
  const update = (code: MatrixRow['code'], weekday: number, patch: Partial<MatrixRow>) =>
    setRows((current) =>
      current.map((row) =>
        row.code === code && row.weekday === weekday ? { ...row, ...patch } : row,
      ),
    );
  const save = async (row: MatrixRow) => {
    if (!row.id) return;
    setError(null);
    setNotice(null);
    setSaving(`${row.code}-${row.weekday}`);
    try {
      if (!row.assigneeId)
        await callEdgeFunction(EDGE_FUNCTIONS.deactivateRecurrence, {
          operation_id: newOperationId(),
          task_definition_id: row.id,
          weekday: row.weekday,
        });
      else
        await callEdgeFunction(EDGE_FUNCTIONS.changeRecurrence, {
          operation_id: newOperationId(),
          task_definition_id: row.id,
          weekday: row.weekday,
          assignee_strategy: 'fixed',
          planned_assignee_user_id: row.assigneeId,
          scheduled_local_time: row.localTime || undefined,
          effective_from: new Date().toLocaleDateString('sv-SE'),
        });
      setNotice('これから毎回の担当を保存しました。');
      await load();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '保存に失敗しました。');
    } finally {
      setSaving(null);
    }
  };
  return (
    <section className="card routine-matrix-card">
      <div className="section-heading">
        <div>
          <h2>送り・お迎え</h2>
          <p className="empty-hint">曜日を押して、その場で保存できます。</p>
        </div>
      </div>
      {loading ? (
        <p role="status">読み込み中…</p>
      ) : (
        <div className="routine-matrix">
          <div className="matrix-head">担当</div>
          {WEEKDAYS.map((day) => (
            <div className="matrix-head" key={day.value}>
              {day.label}
            </div>
          ))}
          {(['dropoff', 'pickup'] as const).map((code) => (
            <>
              <div className="matrix-label" key={`${code}-label`}>
                {code === 'dropoff' ? '送り' : 'お迎え'}
              </div>
              {WEEKDAYS.map((day) => {
                const row = rows.find((item) => item.code === code && item.weekday === day.value);
                if (!row) return <div key={`${code}-${day.value}`} />;
                const key = `${code}-${day.value}`;
                return (
                  <div className="matrix-cell" key={key}>
                    <select
                      aria-label={`${code === 'dropoff' ? '送り' : 'お迎え'} ${day.label}曜日の担当`}
                      value={row.assigneeId}
                      onChange={(event) =>
                        update(code, day.value, { assigneeId: event.target.value })
                      }
                    >
                      <option value="">なし</option>
                      {members.map((member) => (
                        <option value={member.user_id} key={member.user_id}>
                          {member.profile?.display_name ?? '家族'}
                        </option>
                      ))}
                    </select>
                    <input
                      aria-label={`${day.label}曜日の時刻`}
                      type="time"
                      value={row.localTime}
                      onChange={(event) =>
                        update(code, day.value, { localTime: event.target.value })
                      }
                    />
                    <button
                      type="button"
                      className="matrix-save"
                      onClick={() => save(row)}
                      disabled={saving === key}
                    >
                      {saving === key ? '…' : '保存'}
                    </button>
                  </div>
                );
              })}
            </>
          ))}
        </div>
      )}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      {notice && <p role="status">{notice}</p>}
    </section>
  );
}

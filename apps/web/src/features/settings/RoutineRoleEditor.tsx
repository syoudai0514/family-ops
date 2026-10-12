import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS, type EdgeFunctionName } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { supabase } from '../../lib/supabaseClient';
import { WEEKDAYS } from '../../lib/weekdays';
import { withTimeout } from '../../lib/withTimeout';
import {
  groupRoutines,
  hasLockedSchedule,
  routineSummary,
  STRATEGY_LABELS,
  TRANSPORT_ROLE_STRATEGIES,
  type RoutineItem,
  type RoutineRule,
  type RoutineStrategy,
  type RoutineSubtask,
} from './routineRoles';

/**
 * Every routine (定例) in one list, grouped by who does it (owner instruction 2026-10-11).
 * Tap a routine to change its name, checklist, who does it, weekdays and time, 「余裕があれば」,
 * or to stop it. The family no longer needs an AI or a developer to change a routine.
 */
type KeepOr<T> = T | 'keep';
interface Draft {
  title: string;
  subtasks: RoutineSubtask[];
  optional: boolean;
  weekdays: number[];
  strategy: KeepOr<RoutineStrategy>;
  assigneeId: string;
  fallbackAssigneeId: string;
  time: KeepOr<string>;
  phase: 'morning' | 'evening';
}

interface SavePlan {
  draft: Draft;
  definitionId: string;
  nextStep: number;
  steps: Array<{ endpoint: EdgeFunctionName; body: Record<string, unknown>; targetsDefinition: boolean }>;
  message: string;
}

// Keep an interrupted multi-command save together, including after closing its sheet.
// A retried create/checklist command must reuse its original operation ID and payload.
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function validSubtasks(value: unknown): value is RoutineSubtask[] {
  return Array.isArray(value) && value.every((subtask) => isRecord(subtask)
    && typeof subtask.title === 'string' && subtask.title.length <= 240
    && typeof subtask.required === 'boolean'
    && (subtask.id === undefined || (typeof subtask.id === 'string' && subtask.id.length > 0)));
}

function validSavePlan(value: unknown, itemId: string): value is SavePlan {
  if (!isRecord(value) || !isRecord(value.draft) || !Array.isArray(value.steps)
    || typeof value.definitionId !== 'string' || !value.definitionId
    || (itemId !== NEW_ID && value.definitionId !== itemId)
    || !Number.isInteger(value.nextStep) || (value.nextStep as number) < 0 || (value.nextStep as number) > value.steps.length
    || typeof value.message !== 'string') return false;
  const draft = value.draft;
  if (typeof draft.title !== 'string' || draft.title.length > 240 || !validSubtasks(draft.subtasks)
    || typeof draft.optional !== 'boolean' || !Array.isArray(draft.weekdays)
    || !draft.weekdays.every((day) => Number.isInteger(day) && day >= 1 && day <= 7)
    || (draft.strategy !== 'keep' && !EDITABLE_STRATEGIES.includes(draft.strategy as RoutineStrategy))
    || typeof draft.assigneeId !== 'string' || typeof draft.fallbackAssigneeId !== 'string'
    || typeof draft.time !== 'string' || (draft.time !== '' && draft.time !== 'keep' && !/^\d{2}:\d{2}$/.test(draft.time))
    || (draft.phase !== 'morning' && draft.phase !== 'evening')) return false;
  return value.steps.every((step) => {
    if (!isRecord(step) || !isRecord(step.body) || typeof step.body.operation_id !== 'string'
      || !step.body.operation_id || typeof step.targetsDefinition !== 'boolean') return false;
    const body = step.body;
    switch (step.endpoint) {
      case EDGE_FUNCTIONS.createTaskDefinition:
        return itemId === NEW_ID && !step.targetsDefinition && typeof body.code === 'string'
          && typeof body.title === 'string' && body.category === 'household'
          && (body.routine_phase === 'morning' || body.routine_phase === 'evening') && body.completion_mode === 'whole';
      case EDGE_FUNCTIONS.editTaskDefinition:
        return step.targetsDefinition && typeof body.title === 'string';
      case EDGE_FUNCTIONS.replaceRoutineSubtasks:
        return step.targetsDefinition && validSubtasks(body.subtasks);
      case EDGE_FUNCTIONS.setRoutineDefinitionOptions:
        return step.targetsDefinition && typeof body.enabled === 'boolean' && typeof body.include_in_routine_line === 'boolean'
          && (body.default_expectation === undefined || body.default_expectation === 'optional' || body.default_expectation === 'required');
      case EDGE_FUNCTIONS.replaceRecurrenceSchedule:
        return !step.targetsDefinition && Array.isArray(body.replacements) && body.replacements.length === 1
          && body.replacements.every((replacement) => isRecord(replacement) && Array.isArray(replacement.rules)
            && replacement.rules.every((rule) => isRecord(rule) && Number.isInteger(rule.weekday)
              && (rule.weekday as number) >= 1 && (rule.weekday as number) <= 7
              && EDITABLE_STRATEGIES.includes(rule.assignee_strategy as RoutineStrategy)
              && typeof rule.scheduled_local_time === 'string'
              && (rule.planned_assignee_user_id === undefined || typeof rule.planned_assignee_user_id === 'string')
              && (rule.conflict_window_minutes === undefined || (Number.isInteger(rule.conflict_window_minutes)
                && (rule.conflict_window_minutes as number) >= 0 && (rule.conflict_window_minutes as number) <= 720))));
      default:
        return false;
    }
  });
}

function readSavePlan(key: string, itemId: string): SavePlan | null {
  try {
    const value: unknown = JSON.parse(sessionStorage.getItem(key) ?? 'null');
    if (validSavePlan(value, itemId)) return value;
    sessionStorage.removeItem(key);
  } catch {
    try { sessionStorage.removeItem(key); } catch { /* Storage may be unavailable. */ }
  }
  return null;
}

function writeSavePlan(key: string, plan: SavePlan | null) {
  try {
    if (plan) sessionStorage.setItem(key, JSON.stringify(plan));
    else sessionStorage.removeItem(key);
  } catch { /* The mounted sheet also retains its plan when storage is unavailable. */ }
}

const EDITABLE_STRATEGIES: RoutineStrategy[] = [
  'dropoff_assignee', 'pickup_assignee', 'nonpickup_adult', 'next_day_nondropoff_adult',
  'previous_evening_assignee', 'anyone_adult', 'fixed', 'unassigned',
];
const NEW_ID = 'new';

function draftFor(item: RoutineItem): Draft {
  const strategies = [...new Set(item.rules.map((rule) => `${rule.strategy}|${rule.assigneeId ?? ''}|${rule.fallbackAssigneeId ?? ''}`))];
  const times = [...new Set(item.rules.map((rule) => rule.localTime ?? ''))];
  const first = item.rules[0];
  return {
    title: item.title,
    subtasks: item.subtasks.map((subtask) => ({ ...subtask })),
    optional: item.optional,
    weekdays: [...new Set(item.rules.map((rule) => rule.weekday))].sort((a, b) => a - b),
    strategy: strategies.length > 1 ? 'keep' : first?.strategy ?? 'anyone_adult',
    assigneeId: strategies.length > 1 ? '' : first?.assigneeId ?? '',
    fallbackAssigneeId: strategies.length > 1 ? '' : first?.fallbackAssigneeId ?? '',
    time: times.length > 1 ? 'keep' : times[0] ?? '',
    phase: item.phase === 'morning' ? 'morning' : 'evening',
  };
}

function sameSubtasks(a: RoutineSubtask[], b: RoutineSubtask[]) {
  return JSON.stringify(a.map(({ id, title, required }) => [id ?? null, title.trim(), required]))
    === JSON.stringify(b.map(({ id, title, required }) => [id ?? null, title.trim(), required]));
}

export function RoutineRoleEditor() {
  const { household, members, me } = useHousehold();
  const householdId = household?.id ?? null;
  const userId = me?.user_id ?? '';
  const [items, setItems] = useState<RoutineItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [loadedHouseholdId, setLoadedHouseholdId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const loadSequence = useRef(0);

  const memberLabel = useCallback((userId: string) => {
    const member = members.find((m) => m.user_id === userId);
    return member?.profile?.display_name ?? (member?.family_role === 'papa' ? 'パパ' : member?.family_role === 'mama' ? 'ママ' : '家族');
  }, [members]);

  const load = useCallback(async () => {
    const sequence = ++loadSequence.current;
    if (!householdId) { setItems([]); setLoadedHouseholdId(null); setLoading(false); return; }
    setLoading(true);
    setLoadError(null);
    try {
    const [defs, rules, subtasks] = await withTimeout(Promise.all([
      supabase.from('task_definitions')
        .select('id,code,title,task_kind,routine_phase,is_active,default_expectation,include_in_routine_line,sort_order')
        .eq('household_id', householdId).neq('task_kind', 'transport').order('sort_order'),
      supabase.from('recurrence_rules')
        .select('task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,fallback_assignee_id,scheduled_local_time,conflict_window_minutes')
        .eq('household_id', householdId).eq('active', true),
      supabase.from('task_subtask_definitions')
        .select('id,task_definition_id,title,required,sort_order')
        .eq('household_id', householdId).eq('is_active', true).order('sort_order'),
    ]), 12_000);
    if (sequence !== loadSequence.current) return;
    if (defs.error || rules.error || subtasks.error) {
      setLoadError('定例を読み込めませんでした。');
      setLoading(false);
      return;
    }
    type RuleRow = { task_definition_id: string; weekday: number; slot_key: string; assignee_strategy: RoutineStrategy; planned_assignee_id: string | null; fallback_assignee_id: string | null; scheduled_local_time: string | null; conflict_window_minutes?: number; active?: boolean };
    const toRule = (row: RuleRow): RoutineRule => ({
      weekday: row.weekday, strategy: row.assignee_strategy, assigneeId: row.planned_assignee_id,
      fallbackAssigneeId: row.fallback_assignee_id, localTime: row.scheduled_local_time?.slice(0, 5) ?? null, slotKey: row.slot_key,
      conflictWindowMinutes: row.conflict_window_minutes,
    });
    const allRules = (rules.data ?? []) as RuleRow[];
    setItems((defs.data ?? []).filter((def) => def.code !== 'dropoff' && def.code !== 'pickup').map((def) => {
      // Stopping pauses the definition while retaining exactly its active schedule.
      // Historical inactive rows may include weekdays that were deliberately removed.
      const chosen = allRules.filter((rule) => rule.task_definition_id === def.id && rule.active !== false);
      return {
        id: def.id, code: def.code, title: def.title, taskKind: def.task_kind, phase: def.routine_phase,
        active: def.is_active, optional: def.default_expectation === 'optional', includeInLine: def.include_in_routine_line,
        rules: chosen.map(toRule).sort((a, b) => a.weekday - b.weekday),
        subtasks: (subtasks.data ?? []).filter((s) => s.task_definition_id === def.id).map(({ id, title, required }) => ({ id, title, required })),
      };
    }));
    setLoadedHouseholdId(householdId);
    setLoading(false);
    } catch {
      if (sequence !== loadSequence.current) return;
      setLoadError('定例を読み込めませんでした。');
      setLoading(false);
    }
  }, [householdId]);
  useEffect(() => {
    setOpenId(null);
    setNotice(null);
    setSaving(false);
    void load();
    return () => { ++loadSequence.current; };
  }, [load, userId]);

  const groups = useMemo(() => groupRoutines(loadedHouseholdId === householdId ? items : [], memberLabel), [householdId, loadedHouseholdId, items, memberLabel]);
  const newItem: RoutineItem = { id: NEW_ID, code: '', title: '', taskKind: 'evening_chore', phase: 'evening', active: true, optional: false, includeInLine: true, rules: [], subtasks: [] };

  async function afterSave(message: string) {
    setOpenId(null);
    setSaving(false);
    setNotice(message);
    await load();
  }

  return (
    <section className="card routine-role-editor" id="custom-routines" tabIndex={-1}>
      <h2>定例（くり返しやること）</h2>
      <p className="empty-hint">誰がやるかでまとめています。押すと、名前・チェック項目・担当・曜日・時刻を直せます。変更は今日以降の未着手の分から反映され、済んだ記録や途中のチェックはそのまま残ります。</p>
      {loading && <p role="status">定例を確認中…</p>}
      {loadError && <p role="alert" className="error-text">{loadError} <button type="button" className="text-button" onClick={() => void load()}>もう一度読む</button></p>}
      {notice && <p role="status" className="routine-role-notice">{notice}</p>}
      {groups.map((group) => (
        <div key={group.key} className="routine-role-group" id={group.anchor} tabIndex={group.anchor ? -1 : undefined}>
          <h3>{group.title} <small>{group.items.length}件</small></h3>
          {group.hint && <p className="routine-role-hint">{group.hint}</p>}
          <ul className="routine-role-list">
            {group.items.map((item) => (
              <li key={item.id} className={openId === item.id ? 'open' : undefined}>
                <button type="button" className="routine-role-row" aria-expanded={openId === item.id}
                  disabled={saving}
                  onClick={() => { setNotice(null); setOpenId(openId === item.id ? null : item.id); }}>
                  <span className="routine-role-title">{item.title}{item.subtasks.length > 0 && <small>（{item.subtasks.length}項目）</small>}</span>
                  <span className="routine-role-meta">{routineSummary(item, memberLabel)}</span>
                </button>
                {openId === item.id && (
                  <RoutineSheet key={`${householdId}:${userId}:${item.id}`} storageKey={`family-ops:routine-save:v1:${householdId}:${userId}:${item.id}`} item={item} members={members} memberLabel={memberLabel} onCancel={() => setOpenId(null)} onSaved={afterSave} onSavingChange={setSaving} />
                )}
              </li>
            ))}
          </ul>
        </div>
      ))}
      {!loading && !loadError && (
        openId === NEW_ID
          ? <div className="routine-role-new"><h3>定例を追加</h3><RoutineSheet key={`${householdId}:${userId}:${NEW_ID}`} storageKey={`family-ops:routine-save:v1:${householdId}:${userId}:${NEW_ID}`} item={newItem} members={members} memberLabel={memberLabel} onCancel={() => setOpenId(null)} onSaved={afterSave} onSavingChange={setSaving} /></div>
          : <button type="button" className="secondary-button" disabled={saving} onClick={() => { setNotice(null); setOpenId(NEW_ID); }}>＋ 定例を追加</button>
      )}
    </section>
  );
}

function RoutineSheet({ item, members, memberLabel, onCancel, onSaved, onSavingChange, storageKey }: {
  item: RoutineItem;
  members: ReturnType<typeof useHousehold>['members'];
  memberLabel: (userId: string) => string;
  onCancel: () => void;
  onSaved: (message: string) => Promise<void>;
  onSavingChange: (saving: boolean) => void;
  storageKey: string;
}) {
  const isNew = item.id === NEW_ID;
  const initial = useMemo(() => draftFor(item), [item]);
  const [restored] = useState(() => readSavePlan(storageKey, item.id));
  const savePlan = useRef<SavePlan | null>(restored);
  const running = useRef(false);
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);
  const [retryPending, setRetryPending] = useState(!!restored);
  const [draft, setDraft] = useState<Draft>(() => restored?.draft ?? (isNew ? { ...initial, weekdays: [1, 2, 3, 4, 5], strategy: 'anyone_adult', time: '20:00' } : initial));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [canReviewFailedSave, setCanReviewFailedSave] = useState(false);
  const locked = hasLockedSchedule(item);
  const set = (patch: Partial<Draft>) => setDraft((current) => ({ ...current, ...patch }));
  const setSubtask = (index: number, patch: Partial<RoutineSubtask>) =>
    set({ subtasks: draft.subtasks.map((subtask, i) => (i === index ? { ...subtask, ...patch } : subtask)) });

  const scheduleChanged = isNew
    || draft.strategy !== initial.strategy || draft.assigneeId !== initial.assigneeId
    || draft.fallbackAssigneeId !== initial.fallbackAssigneeId || draft.time !== initial.time
    || draft.weekdays.join() !== initial.weekdays.join();

  function rulesToSave() {
    return draft.weekdays.map((weekday) => {
      const existing = item.rules.find((rule) => rule.weekday === weekday) ?? item.rules[0];
      const strategy = draft.strategy === 'keep' ? existing.strategy : draft.strategy;
      const assigneeId = draft.strategy === 'keep' ? existing.assigneeId : draft.assigneeId;
      const fallbackId = draft.strategy === 'keep' ? existing.fallbackAssigneeId : draft.fallbackAssigneeId;
      const time = draft.time === 'keep' ? existing.localTime ?? '' : draft.time;
      return {
        weekday,
        assignee_strategy: strategy,
        planned_assignee_user_id: strategy === 'fixed' ? assigneeId ?? undefined
          : TRANSPORT_ROLE_STRATEGIES.includes(strategy) ? fallbackId || undefined : undefined,
        scheduled_local_time: time,
        ...(existing?.conflictWindowMinutes !== undefined ? { conflict_window_minutes: existing.conflictWindowMinutes } : {}),
      };
    });
  }

  async function save(stop = false) {
    if (running.current) return;
    setError(null);
    setCanReviewFailedSave(false);
    if (!savePlan.current && !stop) {
      if (!draft.title.trim()) { setError('名前を入れてください。'); return; }
      if (draft.subtasks.some((subtask) => !subtask.title.trim())) { setError('空のチェック項目があります。入力するか「外す」を押してください。'); return; }
      if (!locked && draft.weekdays.length === 0) { setError('曜日を1つ以上選んでください。やめるときは「この定例を止める」を押します。'); return; }
      if (!locked && draft.strategy === 'fixed' && !draft.assigneeId) { setError('誰がやるかを選んでください。'); return; }
    } else if (!savePlan.current && stop && !window.confirm(`「${item.title}」を止めますか？\n今日以降のまだやっていない分も消えます。あとで「止めている定例」から再開できます。`)) {
      return;
    }
    if (!savePlan.current) {
      const plan: SavePlan = {
        draft, definitionId: item.id, nextStep: 0, steps: [],
        message: stop ? `「${item.title}」を止めました。` : isNew ? `「${draft.title.trim()}」を追加しました。` : !item.active ? `「${draft.title.trim()}」を再開しました。` : `「${draft.title.trim()}」を保存しました。`,
      };
      const add = (endpoint: EdgeFunctionName, body: Record<string, unknown>, targetsDefinition = true) => {
        plan.steps.push({ endpoint, body: { operation_id: newOperationId(), ...body }, targetsDefinition });
      };
      if (isNew) {
        const kind = draft.phase === 'morning' ? 'morning_chore' : 'evening_chore';
        add(EDGE_FUNCTIONS.createTaskDefinition, {
          code: `${kind}_custom_${newOperationId()}`, title: draft.title.trim(), category: 'household',
          routine_phase: draft.phase, completion_mode: 'whole',
        }, false);
      }
      if (stop) {
        add(EDGE_FUNCTIONS.setRoutineDefinitionOptions, { enabled: false, include_in_routine_line: item.includeInLine });
      } else {
        if (!sameSubtasks(draft.subtasks, item.subtasks)) {
          add(EDGE_FUNCTIONS.replaceRoutineSubtasks, {
            subtasks: draft.subtasks.map(({ id: subtaskId, title, required }) => ({ ...(subtaskId ? { id: subtaskId } : {}), title: title.trim(), required })),
          });
        }
        if (!isNew && draft.title.trim() !== item.title) {
          add(EDGE_FUNCTIONS.editTaskDefinition, { title: draft.title.trim() });
        }
        if (!locked && scheduleChanged) {
          add(EDGE_FUNCTIONS.replaceRecurrenceSchedule, { replacements: [{ task_definition_id: item.id, rules: rulesToSave() }] }, false);
        }
        // Install an edited stopped schedule before resuming materialization.
        if (!item.active || draft.optional !== item.optional) {
          add(EDGE_FUNCTIONS.setRoutineDefinitionOptions, {
            enabled: true, include_in_routine_line: item.includeInLine,
            ...(draft.optional !== item.optional ? { default_expectation: draft.optional ? 'optional' : 'required' } : {}),
          });
        }
      }
      savePlan.current = plan;
      writeSavePlan(storageKey, plan);
      setRetryPending(true);
    }
    running.current = true;
    setBusy(true);
    onSavingChange(true);
    try {
      const plan = savePlan.current!;
      while (plan.nextStep < plan.steps.length) {
        // A household/account change unmounts this sheet. Preserve its plan,
        // but do not issue a follow-up mutation under the new session.
        if (!mounted.current) return;
        const step = plan.steps[plan.nextStep];
        const body = step.targetsDefinition ? { ...step.body, task_definition_id: plan.definitionId }
          : step.endpoint === EDGE_FUNCTIONS.replaceRecurrenceSchedule
            ? { ...step.body, replacements: (step.body.replacements as Array<Record<string, unknown>>).map((replacement) => ({ ...replacement, task_definition_id: plan.definitionId })) }
            : step.body;
        const result = await callEdgeFunction<{ task_definition_id?: string }>(step.endpoint, body);
        if (step.endpoint === EDGE_FUNCTIONS.createTaskDefinition) {
          if (!result?.task_definition_id) throw new Error('追加した定例を確認できませんでした。同じ操作をもう一度確認してください。');
          plan.definitionId = result.task_definition_id;
        }
        ++plan.nextStep;
        writeSavePlan(storageKey, plan);
      }
      if (!mounted.current) return;
      writeSavePlan(storageKey, null);
      savePlan.current = null;
      setRetryPending(false);
      await onSaved(plan.message);
    } catch (err) {
      if (mounted.current) {
        setError(`${err instanceof FamilyOpsApiError || err instanceof Error ? err.message : '保存できませんでした。'} 「同じ内容で再試行」で、保存できたところから続きを確認できます。`);
        setCanReviewFailedSave(err instanceof FamilyOpsApiError && err.outcome !== 'unknown');
      }
    } finally {
      running.current = false;
      if (mounted.current) {
        setBusy(false);
        onSavingChange(false);
      }
    }
  }

  const strategy = draft.strategy;
  return (
    <fieldset className="routine-sheet" disabled={busy} aria-label={`${item.title || '新しい定例'}の編集`}>
      {retryPending && !busy && <p role="status" className="routine-role-hint">前の保存が途中です。同じ内容で続きを確認します。</p>}
      <fieldset disabled={retryPending} style={{ border: 0, padding: 0, margin: 0, minWidth: 0 }}>
      <label>名前<input value={draft.title} maxLength={240} onChange={(e) => set({ title: e.target.value })} /></label>
      {isNew && (
        <div className="routine-sheet-choice" role="radiogroup" aria-label="時間帯">
          {(['morning', 'evening'] as const).map((phase) => (
            <label key={phase} className="weekday-chip"><input type="radio" name="routine-phase" checked={draft.phase === phase} onChange={() => set({ phase })} />{phase === 'morning' ? '朝' : '夜'}</label>
          ))}
        </div>
      )}
      {locked ? (
        <p className="routine-role-hint">曜日と担当はコドモンの設定と連動しているので、ここでは変えられません。</p>
      ) : (
        <>
          <label>
            誰がやる？
            <select value={strategy} onChange={(e) => set({ strategy: e.target.value as KeepOr<RoutineStrategy> })}>
              {initial.strategy === 'keep' && <option value="keep">曜日ごとに今のまま</option>}
              {EDITABLE_STRATEGIES.map((value) => <option key={value} value={value}>{STRATEGY_LABELS[value]}</option>)}
            </select>
          </label>
          {strategy === 'fixed' && (
            <label>
              やる人
              <select value={draft.assigneeId} onChange={(e) => set({ assigneeId: e.target.value })}>
                <option value="">選んでください</option>
                {members.map((member) => <option key={member.user_id} value={member.user_id}>{memberLabel(member.user_id)}</option>)}
              </select>
            </label>
          )}
          {strategy !== 'keep' && TRANSPORT_ROLE_STRATEGIES.includes(strategy) && (
            <label>
              送り迎えがない日にやる人（任意）
              <select value={draft.fallbackAssigneeId} onChange={(e) => set({ fallbackAssigneeId: e.target.value })}>
                <option value="">決めない</option>
                {members.map((member) => <option key={member.user_id} value={member.user_id}>{memberLabel(member.user_id)}</option>)}
              </select>
            </label>
          )}
          <div className="weekday-picker" role="group" aria-label="曜日">
            {WEEKDAYS.map((day) => (
              <label key={day.value} className="weekday-chip">
                <input type="checkbox" checked={draft.weekdays.includes(day.value)}
                  onChange={() => set({ weekdays: draft.weekdays.includes(day.value) ? draft.weekdays.filter((d) => d !== day.value) : [...draft.weekdays, day.value].sort((a, b) => a - b) })} />
                {day.label}
              </label>
            ))}
          </div>
          {draft.time === 'keep' ? (
            <p className="routine-role-hint">時刻は曜日ごとに違います。<button type="button" className="text-button" onClick={() => set({ time: item.rules.find((rule) => rule.localTime)?.localTime ?? '' })}>全部の曜日を同じ時刻にする</button></p>
          ) : (
            <div className="routine-sheet-time">
              <label>時刻<input type="time" value={draft.time} onChange={(e) => set({ time: e.target.value })} /></label>
              <label className="inline-check"><input type="checkbox" checked={draft.time === ''} onChange={(e) => set({ time: e.target.checked ? '' : (initial.time !== 'keep' && initial.time) || '20:00' })} />時刻なし</label>
            </div>
          )}
        </>
      )}
      <label className="inline-check"><input type="checkbox" checked={draft.optional} onChange={(e) => set({ optional: e.target.checked })} />余裕があれば（やらなくても「できなかった」にしない）</label>
      <div className="routine-sheet-subtasks">
        <p className="routine-role-hint">チェック項目（任意）</p>
        {draft.subtasks.map((subtask, index) => (
          <div key={subtask.id ?? `new-${index}`} className="subtask-row">
            <input value={subtask.title} maxLength={240} aria-label={`チェック項目 ${index + 1}`} onChange={(e) => setSubtask(index, { title: e.target.value })} />
            <label className="inline-check"><input type="checkbox" checked={subtask.required} onChange={(e) => setSubtask(index, { required: e.target.checked })} />必須</label>
            <button type="button" className="text-button" onClick={() => set({ subtasks: draft.subtasks.filter((_, i) => i !== index) })}>外す</button>
          </div>
        ))}
        <button type="button" className="text-button" onClick={() => set({ subtasks: [...draft.subtasks, { title: '', required: true }] })}>＋ チェック項目</button>
      </div>
      </fieldset>
      {error && <p role="alert" className="error-text">{error}</p>}
      <div className="routine-sheet-actions">
        <button type="button" onClick={() => void save()}>{busy ? '保存中…' : retryPending ? '同じ内容で再試行' : isNew ? '追加する' : item.active ? '保存' : '再開する'}</button>
        {canReviewFailedSave && <button type="button" className="text-button" onClick={() => {
          writeSavePlan(storageKey, null);
          savePlan.current = null;
          setRetryPending(false);
          void onSaved('保存は途中でした。一覧で反映された内容を確認して、必要な変更を編集し直してください。');
        }}>一覧を確認して編集し直す</button>}
        <button type="button" className="text-button" onClick={onCancel}>やめる</button>
        {!retryPending && !isNew && item.active && !locked && <button type="button" className="text-button routine-sheet-stop" onClick={() => void save(true)}>この定例を止める</button>}
      </div>
    </fieldset>
  );
}

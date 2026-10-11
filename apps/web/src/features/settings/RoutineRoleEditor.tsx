import { useCallback, useEffect, useMemo, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { supabase } from '../../lib/supabaseClient';
import { WEEKDAYS } from '../../lib/weekdays';
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
  const { household, members } = useHousehold();
  const householdId = household?.id ?? null;
  const [items, setItems] = useState<RoutineItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const memberLabel = useCallback((userId: string) => {
    const member = members.find((m) => m.user_id === userId);
    return member?.profile?.display_name ?? (member?.family_role === 'papa' ? 'パパ' : member?.family_role === 'mama' ? 'ママ' : '家族');
  }, [members]);

  const load = useCallback(async () => {
    if (!householdId) { setLoading(false); return; }
    setLoading(true);
    setLoadError(null);
    const [defs, rules, subtasks] = await Promise.all([
      supabase.from('task_definitions')
        .select('id,code,title,task_kind,routine_phase,is_active,default_expectation,include_in_routine_line,sort_order')
        .eq('household_id', householdId).neq('task_kind', 'transport').order('sort_order'),
      supabase.from('recurrence_rules')
        .select('task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,fallback_assignee_id,scheduled_local_time,active,version')
        .eq('household_id', householdId),
      supabase.from('task_subtask_definitions')
        .select('id,task_definition_id,title,required,sort_order')
        .eq('household_id', householdId).eq('is_active', true).order('sort_order'),
    ]);
    if (defs.error || rules.error || subtasks.error) {
      setLoadError('定例を読み込めませんでした。');
      setLoading(false);
      return;
    }
    type RuleRow = { task_definition_id: string; weekday: number; slot_key: string; assignee_strategy: RoutineStrategy; planned_assignee_id: string | null; fallback_assignee_id: string | null; scheduled_local_time: string | null; active: boolean; version: number };
    const toRule = (row: RuleRow): RoutineRule => ({
      weekday: row.weekday, strategy: row.assignee_strategy, assigneeId: row.planned_assignee_id,
      fallbackAssigneeId: row.fallback_assignee_id, localTime: row.scheduled_local_time?.slice(0, 5) ?? null, slotKey: row.slot_key,
    });
    const allRules = (rules.data ?? []) as RuleRow[];
    setItems((defs.data ?? []).filter((def) => def.code !== 'dropoff' && def.code !== 'pickup').map((def) => {
      const own = allRules.filter((rule) => rule.task_definition_id === def.id);
      let chosen = own.filter((rule) => rule.active);
      if (!def.is_active) {
        // A stopped routine reopens with the weekdays and rule it had last.
        const latest = new Map<string, RuleRow>();
        for (const rule of own) {
          const key = `${rule.slot_key}:${rule.weekday}`;
          if (!latest.has(key) || latest.get(key)!.version < rule.version) latest.set(key, rule);
        }
        chosen = [...latest.values()];
      }
      return {
        id: def.id, code: def.code, title: def.title, taskKind: def.task_kind, phase: def.routine_phase,
        active: def.is_active, optional: def.default_expectation === 'optional', includeInLine: def.include_in_routine_line,
        rules: chosen.map(toRule).sort((a, b) => a.weekday - b.weekday),
        subtasks: (subtasks.data ?? []).filter((s) => s.task_definition_id === def.id).map(({ id, title, required }) => ({ id, title, required })),
      };
    }));
    setLoading(false);
  }, [householdId]);
  useEffect(() => { void load(); }, [load]);

  const groups = useMemo(() => groupRoutines(items, memberLabel), [items, memberLabel]);
  const newItem: RoutineItem = { id: NEW_ID, code: '', title: '', taskKind: 'evening_chore', phase: 'evening', active: true, optional: false, includeInLine: true, rules: [], subtasks: [] };

  async function afterSave(message: string) {
    setOpenId(null);
    setNotice(message);
    await load();
  }

  return (
    <section className="card routine-role-editor" id="custom-routines" tabIndex={-1}>
      <h2>定例（くり返しやること）</h2>
      <p className="empty-hint">誰がやるかでまとめています。押すと、名前・チェック項目・担当・曜日・時刻を直せます。変更は今日の分から反映され、済んだ記録はそのまま残ります。</p>
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
                  onClick={() => { setNotice(null); setOpenId(openId === item.id ? null : item.id); }}>
                  <span className="routine-role-title">{item.title}{item.subtasks.length > 0 && <small>（{item.subtasks.length}項目）</small>}</span>
                  <span className="routine-role-meta">{routineSummary(item, memberLabel)}</span>
                </button>
                {openId === item.id && (
                  <RoutineSheet item={item} members={members} memberLabel={memberLabel} onCancel={() => setOpenId(null)} onSaved={afterSave} />
                )}
              </li>
            ))}
          </ul>
        </div>
      ))}
      {!loading && !loadError && (
        openId === NEW_ID
          ? <div className="routine-role-new"><h3>定例を追加</h3><RoutineSheet item={newItem} members={members} memberLabel={memberLabel} onCancel={() => setOpenId(null)} onSaved={afterSave} /></div>
          : <button type="button" className="secondary-button" onClick={() => { setNotice(null); setOpenId(NEW_ID); }}>＋ 定例を追加</button>
      )}
    </section>
  );
}

function RoutineSheet({ item, members, memberLabel, onCancel, onSaved }: {
  item: RoutineItem;
  members: ReturnType<typeof useHousehold>['members'];
  memberLabel: (userId: string) => string;
  onCancel: () => void;
  onSaved: (message: string) => Promise<void>;
}) {
  const isNew = item.id === NEW_ID;
  const initial = useMemo(() => draftFor(item), [item]);
  const [draft, setDraft] = useState<Draft>(() => isNew ? { ...initial, weekdays: [1, 2, 3, 4, 5], strategy: 'anyone_adult', time: '20:00' } : initial);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const locked = hasLockedSchedule(item);
  const set = (patch: Partial<Draft>) => setDraft((current) => ({ ...current, ...patch }));
  const setSubtask = (index: number, patch: Partial<RoutineSubtask>) =>
    set({ subtasks: draft.subtasks.map((subtask, i) => (i === index ? { ...subtask, ...patch } : subtask)) });

  const scheduleChanged = isNew || !item.active
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
      };
    });
  }

  async function save(stop = false) {
    setError(null);
    if (!stop) {
      if (!draft.title.trim()) { setError('名前を入れてください。'); return; }
      if (draft.subtasks.some((subtask) => !subtask.title.trim())) { setError('空のチェック項目があります。入力するか「外す」を押してください。'); return; }
      if (!locked && draft.weekdays.length === 0) { setError('曜日を1つ以上選んでください。やめるときは「この定例を止める」を押します。'); return; }
      if (!locked && draft.strategy === 'fixed' && !draft.assigneeId) { setError('誰がやるかを選んでください。'); return; }
    } else if (!window.confirm(`「${item.title}」を止めますか？\n今日以降のまだやっていない分も消えます。あとで「止めている定例」から再開できます。`)) {
      return;
    }
    setBusy(true);
    try {
      let id = item.id;
      if (isNew) {
        const kind = draft.phase === 'morning' ? 'morning_chore' : 'evening_chore';
        const created = await callEdgeFunction<{ task_definition_id: string }>(EDGE_FUNCTIONS.createTaskDefinition, {
          operation_id: newOperationId(), code: `${kind}_custom_${Date.now()}`, title: draft.title.trim(), category: 'household',
          routine_phase: draft.phase, completion_mode: 'whole',
        });
        id = created.task_definition_id;
      }
      if (stop) {
        await callEdgeFunction(EDGE_FUNCTIONS.setRoutineDefinitionOptions, { operation_id: newOperationId(), task_definition_id: id, enabled: false, include_in_routine_line: item.includeInLine });
        await onSaved(`「${item.title}」を止めました。`);
        return;
      }
      if (!sameSubtasks(draft.subtasks, item.subtasks)) {
        await callEdgeFunction(EDGE_FUNCTIONS.replaceRoutineSubtasks, {
          operation_id: newOperationId(), task_definition_id: id,
          subtasks: draft.subtasks.map(({ id: subtaskId, title, required }) => ({ ...(subtaskId ? { id: subtaskId } : {}), title: title.trim(), required })),
        });
      }
      if (!isNew && draft.title.trim() !== item.title) {
        await callEdgeFunction(EDGE_FUNCTIONS.editTaskDefinition, { operation_id: newOperationId(), task_definition_id: id, title: draft.title.trim() });
      }
      if (!item.active || draft.optional !== item.optional) {
        await callEdgeFunction(EDGE_FUNCTIONS.setRoutineDefinitionOptions, {
          operation_id: newOperationId(), task_definition_id: id, enabled: true, include_in_routine_line: item.includeInLine,
          ...(draft.optional !== item.optional ? { default_expectation: draft.optional ? 'optional' : 'required' } : {}),
        });
      }
      if (!locked && scheduleChanged) {
        await callEdgeFunction(EDGE_FUNCTIONS.replaceRecurrenceSchedule, { operation_id: newOperationId(), replacements: [{ task_definition_id: id, rules: rulesToSave() }] });
      }
      await onSaved(isNew ? `「${draft.title.trim()}」を追加しました。` : !item.active ? `「${draft.title.trim()}」を再開しました。` : `「${draft.title.trim()}」を保存しました。`);
    } catch (err) {
      setError(`${err instanceof FamilyOpsApiError || err instanceof Error ? err.message : '保存できませんでした。'} 途中まで保存された場合があります。一覧を確かめてください。`);
      setBusy(false);
    }
  }

  const strategy = draft.strategy;
  return (
    <fieldset className="routine-sheet" disabled={busy} aria-label={`${item.title || '新しい定例'}の編集`}>
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
      {error && <p role="alert" className="error-text">{error}</p>}
      <div className="routine-sheet-actions">
        <button type="button" onClick={() => void save()}>{busy ? '保存中…' : isNew ? '追加する' : item.active ? '保存' : '再開する'}</button>
        <button type="button" className="text-button" onClick={onCancel}>やめる</button>
        {!isNew && item.active && !locked && <button type="button" className="text-button routine-sheet-stop" onClick={() => void save(true)}>この定例を止める</button>}
      </div>
    </fieldset>
  );
}

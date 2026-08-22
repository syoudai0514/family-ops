import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { WEEKDAYS } from '../../lib/weekdays';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';

type SubtaskDraft = { id?: string; title: string; required: boolean };
type Row = { id: string; title: string; is_active: boolean; include_in_routine_line: boolean; weekdays: number[]; localTime: string; strategy: string; assignee: string; subtasks: SubtaskDraft[] };

// `code` is the durable domain marker.  Do not infer "custom" from a title:
// built-in chores may be renamed by a household, but must remain owned by
// EveningRoutineEditor so their independent weekday patterns are never folded
// into this editor's single schedule form.
export function isCustomRoutineDefinition(kind: 'morning_chore' | 'evening_chore', code: string | null | undefined) {
  if (!code) return false;
  const phase = kind === 'morning_chore' ? 'morning' : 'evening';
  return code.startsWith(`${kind}_custom_`) || code.startsWith(`${phase}_custom_`);
}

function customRoutineCodeFilter(kind: 'morning_chore' | 'evening_chore') {
  const phase = kind === 'morning_chore' ? 'morning' : 'evening';
  return `code.like.${kind}_custom_%,code.like.${phase}_custom_%`;
}

function move<T>(items: T[], from: number, to: number) {
  if (to < 0 || to >= items.length) return items;
  const next = [...items];
  const [entry] = next.splice(from, 1);
  next.splice(to, 0, entry);
  return next;
}

export function CustomRoutineEditor({ householdId, members, kind }: { householdId: string | null; members: HouseholdMemberWithProfile[]; kind: 'morning_chore' | 'evening_chore' }) {
  const [rows, setRows] = useState<Row[]>([]);
  const [title, setTitle] = useState('');
  const [days, setDays] = useState<number[]>([]);
  const [time, setTime] = useState(kind === 'morning_chore' ? '07:00' : '20:00');
  const [strategy, setStrategy] = useState('fixed');
  const [assignee, setAssignee] = useState('');
  const [line, setLine] = useState(true);
  const [subtaskText, setSubtaskText] = useState('');
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!householdId) return;
    const [defs, rules, subtasks] = await Promise.all([
      supabase.from('task_definitions').select('id,code,title,is_active,include_in_routine_line').eq('household_id', householdId).eq('task_kind', kind).or(customRoutineCodeFilter(kind)),
      supabase.from('recurrence_rules').select('task_definition_id,weekday,scheduled_local_time,assignee_strategy,planned_assignee_id').eq('household_id', householdId).eq('active', true),
      supabase.from('task_subtask_definitions').select('id,task_definition_id,title,required,sort_order,is_active').eq('household_id', householdId).eq('is_active', true).order('sort_order'),
    ]);
    if (defs.error || rules.error || subtasks.error) {
      setError(defs.error?.message ?? rules.error?.message ?? subtasks.error?.message ?? '読み込みに失敗しました。');
      return;
    }
    setRows((defs.data ?? []).filter((definition) => isCustomRoutineDefinition(kind, definition.code)).map((definition) => {
      const definitionRules = (rules.data ?? []).filter((rule) => rule.task_definition_id === definition.id);
      return { id: definition.id, title: definition.title, is_active: definition.is_active, include_in_routine_line: definition.include_in_routine_line,
        weekdays: definitionRules.map((rule) => rule.weekday), localTime: definitionRules[0]?.scheduled_local_time?.slice(0, 5) ?? time,
        strategy: definitionRules[0]?.assignee_strategy ?? 'fixed', assignee: definitionRules[0]?.planned_assignee_id ?? '',
        subtasks: (subtasks.data ?? []).filter((subtask) => subtask.task_definition_id === definition.id).map((subtask) => ({ id: subtask.id, title: subtask.title, required: subtask.required })),
      };
    }));
  }, [householdId, kind, time]);
  useEffect(() => { void load(); }, [load]);

  const update = (id: string, patch: Partial<Row>) => setRows((current) => current.map((row) => row.id === id ? { ...row, ...patch } : row));
  const updateSubtasks = (row: Row, subtasks: SubtaskDraft[]) => update(row.id, { subtasks });
  const save = async (row: Row) => {
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.replaceRoutineSubtasks, { operation_id: newOperationId(), task_definition_id: row.id, subtasks: row.subtasks.map((subtask, sort_order) => ({ ...subtask, sort_order })) });
      await callEdgeFunction(EDGE_FUNCTIONS.editTaskDefinition, { operation_id: newOperationId(), task_definition_id: row.id, title: row.title, routine_phase: kind === 'morning_chore' ? 'morning' : 'evening' });
      await callEdgeFunction(EDGE_FUNCTIONS.setRoutineDefinitionOptions, { operation_id: newOperationId(), task_definition_id: row.id, enabled: row.is_active, include_in_routine_line: row.include_in_routine_line });
      if (row.is_active) await callEdgeFunction(EDGE_FUNCTIONS.replaceRecurrenceSchedule, { operation_id: newOperationId(), replacements: [{ task_definition_id: row.id, rules: row.weekdays.map((weekday) => ({ weekday, assignee_strategy: row.strategy, planned_assignee_user_id: row.strategy === 'fixed' ? row.assignee : undefined, scheduled_local_time: row.localTime })) }] });
      await load();
    } catch (cause) { setError(cause instanceof Error ? cause.message : '保存に失敗しました。'); }
  };
  const add = async () => {
    if (!title.trim() || !days.length) { setError('名前と曜日を入力してください。'); return; }
    try {
      const subtasks = subtaskText.split(/\n|,/).map((item) => item.trim()).filter(Boolean).map((item, sort_order) => ({ title: item, sort_order, required: true }));
      const created = await callEdgeFunction<{ task_definition_id: string }>(EDGE_FUNCTIONS.createTaskDefinition, { operation_id: newOperationId(), code: `${kind}_custom_${Date.now()}`, title: title.trim(), category: 'household', routine_phase: kind === 'morning_chore' ? 'morning' : 'evening', completion_mode: subtasks.length ? 'subtasks' : 'whole', subtasks: subtasks.length ? subtasks : undefined });
      await save({ id: created.task_definition_id, title: title.trim(), is_active: true, include_in_routine_line: line, weekdays: days, localTime: time, strategy, assignee, subtasks });
      setTitle(''); setDays([]); setSubtaskText('');
    } catch (cause) { setError(cause instanceof Error ? cause.message : '追加に失敗しました。'); }
  };
  const dayPicker = (selected: number[], change: (value: number[]) => void) => <div className="weekday-picker">{WEEKDAYS.map((day) => <label key={day.value} className="weekday-chip"><input type="checkbox" checked={selected.includes(day.value)} onChange={() => change(selected.includes(day.value) ? selected.filter((value) => value !== day.value) : [...selected, day.value])} />{day.label}</label>)}</div>;
  const label = kind === 'morning_chore' ? '朝の定例家事' : '夜の定例家事';
  return <section className="card routine-editor"><h2>{label}</h2><p className="empty-hint">追加した項目はToday・LINE・Historyに出ます。月・週やGoogle Calendarには出ません。</p>
    {rows.map((row) => <article key={row.id} className="routine-rule"><input value={row.title} onChange={(event) => update(row.id, { title: event.target.value })} aria-label={`${row.title}の名前`} /><label><input type="checkbox" checked={row.is_active} onChange={(event) => update(row.id, { is_active: event.target.checked })} />有効</label><label><input type="checkbox" checked={row.include_in_routine_line} onChange={(event) => update(row.id, { include_in_routine_line: event.target.checked })} />LINEチェックリストへ含める</label>{dayPicker(row.weekdays, (weekdays) => update(row.id, { weekdays }))}<input type="time" value={row.localTime} onChange={(event) => update(row.id, { localTime: event.target.value })} /><select value={row.strategy} onChange={(event) => update(row.id, { strategy: event.target.value })}><option value="fixed">固定担当</option><option value="dropoff_assignee">送り担当</option><option value="pickup_assignee">迎え担当</option><option value="nonpickup_adult">迎え以外</option></select>{row.strategy === 'fixed' && <select value={row.assignee} onChange={(event) => update(row.id, { assignee: event.target.value })}><option value="">選択</option>{members.map((member) => <option key={member.user_id} value={member.user_id}>{member.profile?.display_name ?? member.user_id}</option>)}</select>}
      <fieldset className="routine-subtasks"><legend>子タスク</legend>{row.subtasks.map((subtask, index) => <div className="subtask-row" key={subtask.id ?? `new-${index}`}><input value={subtask.title} onChange={(event) => updateSubtasks(row, row.subtasks.map((item, itemIndex) => itemIndex === index ? { ...item, title: event.target.value } : item))} aria-label={`子タスク ${index + 1}`} /><label className="inline-check"><input type="checkbox" checked={subtask.required} onChange={(event) => updateSubtasks(row, row.subtasks.map((item, itemIndex) => itemIndex === index ? { ...item, required: event.target.checked } : item))} />必須</label><button type="button" className="secondary-button" onClick={() => updateSubtasks(row, move(row.subtasks, index, index - 1))} disabled={index === 0}>↑</button><button type="button" className="secondary-button" onClick={() => updateSubtasks(row, move(row.subtasks, index, index + 1))} disabled={index === row.subtasks.length - 1}>↓</button><button type="button" className="danger-button" onClick={() => updateSubtasks(row, row.subtasks.filter((_, itemIndex) => itemIndex !== index))}>削除</button></div>)}<button type="button" className="secondary-button" onClick={() => updateSubtasks(row, [...row.subtasks, { title: '', required: true }])}>子タスクを追加</button></fieldset><button type="button" onClick={() => void save(row)}>保存</button></article>)}
    <div className="add-preparation"><h3>＋ 項目を追加</h3><input value={title} onChange={(event) => setTitle(event.target.value)} placeholder="例: ゴミ出し" /><textarea value={subtaskText} onChange={(event) => setSubtaskText(event.target.value)} placeholder="任意の子タスク（改行またはカンマ区切り）" />{dayPicker(days, setDays)}<input type="time" value={time} onChange={(event) => setTime(event.target.value)} /><select value={strategy} onChange={(event) => setStrategy(event.target.value)}><option value="fixed">固定担当</option><option value="dropoff_assignee">送り担当</option><option value="pickup_assignee">迎え担当</option></select>{strategy === 'fixed' && <select value={assignee} onChange={(event) => setAssignee(event.target.value)}><option value="">選択</option>{members.map((member) => <option key={member.user_id} value={member.user_id}>{member.profile?.display_name ?? member.user_id}</option>)}</select>}<label><input type="checkbox" checked={line} onChange={(event) => setLine(event.target.checked)} />LINEチェックリストへ含める</label><button type="button" onClick={() => void add()}>追加する</button></div>{error && <p role="alert" className="error-text">{error}</p>}
  </section>;
}

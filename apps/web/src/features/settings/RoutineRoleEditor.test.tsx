import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { groupRoutines, weekdaySummary, type RoutineItem } from './routineRoles';
import { RoutineRoleEditor } from './RoutineRoleEditor';

const PAPA = 'user-papa';
const MAMA = 'user-mama';
const callEdgeFunction = vi.fn();
const tables: Record<string, unknown[]> = {};

vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return { ...actual, callEdgeFunction: (...args: unknown[]) => callEdgeFunction(...args) };
});
vi.mock('../../lib/supabaseClient', () => {
  const query = (table: string) => {
    const result = { data: tables[table] ?? [], error: null };
    const chain: Record<string, unknown> = {};
    for (const method of ['select', 'eq', 'neq', 'order']) chain[method] = () => chain;
    chain.then = (resolve: (value: typeof result) => unknown) => Promise.resolve(result).then(resolve);
    return chain;
  };
  return { supabase: { from: query } };
});
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({
    household: { id: 'hh-1' },
    members: [
      { user_id: PAPA, family_role: 'papa', profile: { display_name: 'パパ' } },
      { user_id: MAMA, family_role: 'mama', profile: { display_name: 'ママ' } },
    ],
  }),
}));

const def = (id: string, title: string, extra: Record<string, unknown> = {}) => ({
  id, code: id, title, task_kind: 'evening_chore', routine_phase: 'evening', is_active: true,
  default_expectation: null, include_in_routine_line: true, sort_order: 1, ...extra,
});
const rule = (taskId: string, weekday: number, strategy: string, extra: Record<string, unknown> = {}) => ({
  task_definition_id: taskId, weekday, slot_key: 'default', assignee_strategy: strategy, planned_assignee_id: null,
  fallback_assignee_id: null, scheduled_local_time: '20:00:00', active: true, version: 1, ...extra,
});
const weekdays = [1, 2, 3, 4, 5];

function seed() {
  tables.task_definitions = [
    def('bath', 'お風呂'),
    def('breakfast', '朝ごはん', { task_kind: 'morning_chore', routine_phase: 'morning' }),
    def('homework', '将生の言語の宿題'),
    def('window', '窓拭き', { task_kind: 'generic_once', routine_phase: 'anytime', default_expectation: 'optional' }),
    def('toilet', 'トイレ掃除', { task_kind: 'generic_once', routine_phase: 'anytime' }),
    def('codmon', '詩乃：コドモン入力（迎え）', { task_kind: 'morning_chore', routine_phase: 'morning' }),
    def('cold', '詩乃（風邪）の薬', { is_active: false }),
    def('dropoff', '送り', { task_kind: 'transport' }),
  ];
  tables.recurrence_rules = [
    ...weekdays.map((d) => rule('bath', d, 'pickup_assignee')),
    ...weekdays.map((d) => rule('breakfast', d, 'dropoff_assignee', { scheduled_local_time: '07:00:00' })),
    ...[1, 2, 3].map((d) => rule('homework', d, 'pickup_assignee', { scheduled_local_time: null })),
    ...[4, 5].map((d) => rule('homework', d, 'anyone_adult', { scheduled_local_time: null })),
    ...weekdays.map((d) => rule('window', d, 'anyone_adult', { scheduled_local_time: null })),
    rule('toilet', 6, 'fixed', { planned_assignee_id: PAPA, scheduled_local_time: null }),
    ...weekdays.map((d) => rule('codmon', d, 'pickup_assignee', { slot_key: 'codmon', scheduled_local_time: '09:15:00' })),
    ...[1, 2, 3, 4, 5, 6, 7].map((d) => rule('cold', d, 'pickup_assignee', { active: false, version: 2, scheduled_local_time: '20:45:00' })),
  ];
  tables.task_subtask_definitions = [];
}

async function openRoutine(title: string) {
  fireEvent.click(await screen.findByRole('button', { name: new RegExp(`^${title}`) }));
  return screen.getByRole('group', { name: `${title}の編集` });
}

describe('routines grouped by who does them', () => {
  beforeEach(() => {
    seed();
    callEdgeFunction.mockReset();
    callEdgeFunction.mockResolvedValue({ ok: true });
    vi.spyOn(window, 'confirm').mockReturnValue(true);
  });

  it('lists every routine except the transport legs under who does it', async () => {
    render(<RoutineRoleEditor />);
    const headings = (await screen.findAllByRole('heading', { level: 3 })).map((h) => h.textContent);
    expect(headings).toEqual([
      '送りの人がやること 1件', '迎えの人がやること 2件', 'パパがやること（固定） 1件',
      '曜日で担当が変わる 1件', '余裕があれば 1件', '止めている定例 1件',
    ]);
    expect(screen.queryByRole('button', { name: /^送り/ })).toBeNull();
    expect(screen.getByRole('button', { name: /^将生の言語の宿題/ })).toHaveTextContent('迎えの人／誰でもOK');
  });

  it('moves a routine to another role for every weekday and keeps its time', async () => {
    render(<RoutineRoleEditor />);
    const sheet = await openRoutine('お風呂');
    fireEvent.change(within(sheet).getByLabelText('誰がやる？'), { target: { value: 'anyone_adult' } });
    fireEvent.click(within(sheet).getByRole('button', { name: '保存' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(1));
    const [name, body] = callEdgeFunction.mock.calls[0];
    expect(name).toBe('replace-recurrence-schedule');
    expect(body.replacements).toEqual([{ task_definition_id: 'bath', rules: weekdays.map((weekday) => ({
      weekday, assignee_strategy: 'anyone_adult', planned_assignee_user_id: undefined, scheduled_local_time: '20:00',
    })) }]);
  });

  it('keeps the per-weekday rule of a mixed routine when only a weekday is added', async () => {
    render(<RoutineRoleEditor />);
    const sheet = await openRoutine('将生の言語の宿題');
    expect(within(sheet).getByLabelText('誰がやる？')).toHaveValue('keep');
    fireEvent.click(within(sheet).getByLabelText('土'));
    fireEvent.click(within(sheet).getByRole('button', { name: '保存' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalled());
    const rules = callEdgeFunction.mock.calls[0][1].replacements[0].rules;
    expect(rules.map((r: { weekday: number; assignee_strategy: string }) => [r.weekday, r.assignee_strategy])).toEqual([
      [1, 'pickup_assignee'], [2, 'pickup_assignee'], [3, 'pickup_assignee'], [4, 'anyone_adult'], [5, 'anyone_adult'], [6, 'pickup_assignee'],
    ]);
  });

  it('saves only what changed: a new name and 余裕があれば do not rewrite the schedule', async () => {
    render(<RoutineRoleEditor />);
    const sheet = await openRoutine('お風呂');
    fireEvent.change(within(sheet).getByLabelText('名前'), { target: { value: 'お風呂（子ども）' } });
    fireEvent.click(within(sheet).getByLabelText(/余裕があれば/));
    fireEvent.click(within(sheet).getByRole('button', { name: '保存' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(2));
    expect(callEdgeFunction.mock.calls.map((call) => call[0])).toEqual(['edit-task-definition', 'set-routine-definition-options']);
    expect(callEdgeFunction.mock.calls[1][1]).toEqual(expect.objectContaining({ enabled: true, default_expectation: 'optional' }));
  });

  it('stops a routine after confirming, and restarts a stopped one with its last weekdays', async () => {
    render(<RoutineRoleEditor />);
    let sheet = await openRoutine('お風呂');
    fireEvent.click(within(sheet).getByRole('button', { name: 'この定例を止める' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('set-routine-definition-options', expect.objectContaining({ task_definition_id: 'bath', enabled: false })));

    callEdgeFunction.mockClear();
    sheet = await openRoutine('詩乃（風邪）の薬');
    fireEvent.click(within(sheet).getByRole('button', { name: '再開する' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(2));
    expect(callEdgeFunction.mock.calls[0]).toEqual(['set-routine-definition-options', expect.objectContaining({ task_definition_id: 'cold', enabled: true })]);
    expect(callEdgeFunction.mock.calls[1][1].replacements[0].rules).toHaveLength(7);
  });

  it('does not offer to change the weekdays or role of a Codmon routine', async () => {
    render(<RoutineRoleEditor />);
    const sheet = await openRoutine('詩乃：コドモン入力（迎え）');
    expect(within(sheet).queryByLabelText('誰がやる？')).toBeNull();
    expect(within(sheet).queryByRole('button', { name: 'この定例を止める' })).toBeNull();
    expect(within(sheet).getByText(/コドモンの設定と連動/)).toBeInTheDocument();
  });

  it('adds a routine with its role, weekdays and time', async () => {
    callEdgeFunction.mockImplementation(async (name: string) => (name === 'create-task-definition' ? { task_definition_id: 'new-def' } : { ok: true }));
    render(<RoutineRoleEditor />);
    fireEvent.click(await screen.findByRole('button', { name: '＋ 定例を追加' }));
    const sheet = screen.getByRole('group', { name: '新しい定例の編集' });
    fireEvent.change(within(sheet).getByLabelText('名前'), { target: { value: 'ゴミ出し' } });
    fireEvent.click(within(sheet).getByLabelText('朝'));
    fireEvent.change(within(sheet).getByLabelText('誰がやる？'), { target: { value: 'dropoff_assignee' } });
    fireEvent.click(within(sheet).getByRole('button', { name: '追加する' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(2));
    expect(callEdgeFunction.mock.calls[0][1]).toEqual(expect.objectContaining({ title: 'ゴミ出し', routine_phase: 'morning', code: expect.stringMatching(/^morning_chore_custom_/) }));
    expect(callEdgeFunction.mock.calls[1][1].replacements[0]).toEqual(expect.objectContaining({ task_definition_id: 'new-def' }));
    expect(callEdgeFunction.mock.calls[1][1].replacements[0].rules[0].assignee_strategy).toBe('dropoff_assignee');
  });
});

describe('routine summaries', () => {
  it('describes weekdays the way the family says them', () => {
    expect(weekdaySummary([1, 2, 3, 4, 5])).toBe('月〜金');
    expect(weekdaySummary([1, 2, 3, 4, 5, 6, 7])).toBe('毎日');
    expect(weekdaySummary([2, 6])).toBe('火・土');
  });

  it('puts each fixed person in their own group', () => {
    const item = (id: string, assigneeId: string): RoutineItem => ({
      id, code: id, title: id, taskKind: 'generic_once', phase: 'anytime', active: true, optional: false, includeInLine: true, subtasks: [],
      rules: [{ weekday: 6, strategy: 'fixed', assigneeId, fallbackAssigneeId: null, localTime: null, slotKey: 'default' }],
    });
    const groups = groupRoutines([item('a', PAPA), item('b', MAMA)], (id) => (id === PAPA ? 'パパ' : 'ママ'));
    expect(groups.map((g) => g.title)).toEqual(['ママがやること（固定）', 'パパがやること（固定）']);
  });
});

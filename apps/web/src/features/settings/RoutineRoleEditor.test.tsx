import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { groupRoutines, weekdaySummary, type RoutineItem } from './routineRoles';
import { RoutineRoleEditor } from './RoutineRoleEditor';
import { FamilyOpsApiError } from '../../lib/apiClient';

const PAPA = 'user-papa';
const MAMA = 'user-mama';
const callEdgeFunction = vi.fn();
const tables: Record<string, unknown[]> = {};
let currentUserId = '';

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
    me: { user_id: currentUserId },
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
    ...[1, 2, 3, 4, 5, 6, 7].map((d) => rule('cold', d, 'pickup_assignee', { version: 2, scheduled_local_time: '20:45:00' })),
  ];
  tables.task_subtask_definitions = [];
}

async function openRoutine(title: string) {
  fireEvent.click(await screen.findByRole('button', { name: new RegExp(`^${title}`) }));
  return screen.getByRole('group', { name: `${title}の編集` });
}

describe('routines grouped by who does them', () => {
  beforeEach(() => {
    sessionStorage.clear();
    currentUserId = '';
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
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(1));
    expect(callEdgeFunction.mock.calls[0]).toEqual(['set-routine-definition-options', expect.objectContaining({ task_definition_id: 'cold', enabled: true })]);
    expect(within(sheet).getByLabelText('日')).toBeChecked();
  });

  it('never restores weekdays removed before a routine was stopped', async () => {
    tables.recurrence_rules = [
      rule('cold', 1, 'pickup_assignee', { active: true, version: 1 }),
      rule('cold', 6, 'anyone_adult', { active: false, version: 9 }),
    ];
    render(<RoutineRoleEditor />);
    const sheet = await openRoutine('詩乃（風邪）の薬');
    expect(within(sheet).getByLabelText('月')).toBeChecked();
    expect(within(sheet).getByLabelText('土')).not.toBeChecked();
    fireEvent.click(within(sheet).getByRole('button', { name: '再開する' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(1));
    expect(callEdgeFunction.mock.calls[0][0]).toBe('set-routine-definition-options');
  });

  it('asks for weekdays instead of guessing a legacy stopped schedule from history', async () => {
    tables.recurrence_rules = [rule('cold', 6, 'anyone_adult', { active: false })];
    render(<RoutineRoleEditor />);
    const sheet = await openRoutine('詩乃（風邪）の薬');
    fireEvent.click(within(sheet).getByRole('button', { name: '再開する' }));
    expect(within(sheet).getByRole('alert')).toHaveTextContent('曜日を1つ以上');
    expect(callEdgeFunction).not.toHaveBeenCalled();
    fireEvent.click(within(sheet).getByLabelText('月'));
    fireEvent.click(within(sheet).getByRole('button', { name: '再開する' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(2));
    expect(callEdgeFunction.mock.calls.map((call) => call[0])).toEqual(['replace-recurrence-schedule', 'set-routine-definition-options']);
  });

  it('installs the edited weekdays before restarting a stopped routine', async () => {
    render(<RoutineRoleEditor />);
    const sheet = await openRoutine('詩乃（風邪）の薬');
    fireEvent.click(within(sheet).getByLabelText('土'));
    fireEvent.click(within(sheet).getByRole('button', { name: '再開する' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(2));
    expect(callEdgeFunction.mock.calls.map((call) => call[0])).toEqual(['replace-recurrence-schedule', 'set-routine-definition-options']);
    expect(callEdgeFunction.mock.calls[0][1].replacements[0].rules.map((r: { weekday: number }) => r.weekday)).toEqual([1, 2, 3, 4, 5, 7]);
  });

  it('preserves per-weekday times, fallback people and conflict windows when adding a day', async () => {
    tables.recurrence_rules = [
      rule('bath', 1, 'pickup_assignee', { fallback_assignee_id: PAPA, scheduled_local_time: '20:00:00', conflict_window_minutes: 30 }),
      rule('bath', 2, 'fixed', { planned_assignee_id: MAMA, scheduled_local_time: null, conflict_window_minutes: 90 }),
    ];
    render(<RoutineRoleEditor />);
    const sheet = await openRoutine('お風呂');
    fireEvent.click(within(sheet).getByLabelText('土'));
    fireEvent.click(within(sheet).getByRole('button', { name: '保存' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(1));
    expect(callEdgeFunction.mock.calls[0][1].replacements[0].rules).toEqual([
      { weekday: 1, assignee_strategy: 'pickup_assignee', planned_assignee_user_id: PAPA, scheduled_local_time: '20:00', conflict_window_minutes: 30 },
      { weekday: 2, assignee_strategy: 'fixed', planned_assignee_user_id: MAMA, scheduled_local_time: '', conflict_window_minutes: 90 },
      { weekday: 6, assignee_strategy: 'pickup_assignee', planned_assignee_user_id: PAPA, scheduled_local_time: '20:00', conflict_window_minutes: 30 },
    ]);
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

  it('resumes a failed add after reopening without creating another definition', async () => {
    callEdgeFunction.mockImplementation(async (name: string) => (name === 'create-task-definition' ? { task_definition_id: 'new-def' } : { ok: true }));
    callEdgeFunction.mockImplementationOnce(async () => ({ task_definition_id: 'new-def' }));
    callEdgeFunction.mockRejectedValueOnce(new FamilyOpsApiError('RESULT_UNKNOWN', '通信が途切れました', 0, undefined, 'unknown'));
    render(<RoutineRoleEditor />);
    fireEvent.click(await screen.findByRole('button', { name: '＋ 定例を追加' }));
    let sheet = screen.getByRole('group', { name: '新しい定例の編集' });
    fireEvent.change(within(sheet).getByLabelText('名前'), { target: { value: 'ゴミ出し' } });
    fireEvent.click(within(sheet).getByRole('button', { name: '追加する' }));
    await screen.findByRole('alert');
    const failedCall = callEdgeFunction.mock.calls[1];
    expect(within(sheet).getByLabelText('名前')).toBeDisabled();
    expect(within(sheet).queryByRole('button', { name: '一覧を確認して編集し直す' })).toBeNull();
    fireEvent.click(within(sheet).getByRole('button', { name: 'やめる' }));
    fireEvent.click(screen.getByRole('button', { name: '＋ 定例を追加' }));
    sheet = screen.getByRole('group', { name: '新しい定例の編集' });
    expect(within(sheet).getByLabelText('名前')).toHaveValue('ゴミ出し');
    fireEvent.click(within(sheet).getByRole('button', { name: '同じ内容で再試行' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(3));
    expect(callEdgeFunction.mock.calls[2]).toEqual(failedCall);
    expect(callEdgeFunction.mock.calls.filter((call) => call[0] === 'create-task-definition')).toHaveLength(1);
  });

  it('retries an uncertain checklist save with its original operation ID', async () => {
    callEdgeFunction.mockRejectedValueOnce(new FamilyOpsApiError('RESULT_UNKNOWN', '通信が途切れました', 0, undefined, 'unknown'));
    render(<RoutineRoleEditor />);
    const sheet = await openRoutine('お風呂');
    fireEvent.click(within(sheet).getByRole('button', { name: '＋ チェック項目' }));
    fireEvent.change(within(sheet).getByLabelText('チェック項目 1'), { target: { value: 'タオルを出す' } });
    fireEvent.click(within(sheet).getByRole('button', { name: '保存' }));
    await screen.findByRole('alert');
    fireEvent.click(within(sheet).getByRole('button', { name: '同じ内容で再試行' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(2));
    expect(callEdgeFunction.mock.calls[1]).toEqual(callEdgeFunction.mock.calls[0]);
  });

  it.each(['{', '42', '{"draft":{"subtasks":null}}'])('opens the current routine when stored save data is malformed: %s', async (stored) => {
    const key = 'family-ops:routine-save:v1:hh-1::bath';
    sessionStorage.setItem(key, stored);
    render(<RoutineRoleEditor />);
    const sheet = await openRoutine('お風呂');
    expect(within(sheet).getByLabelText('名前')).toHaveValue('お風呂');
    expect(within(sheet).getByLabelText('名前')).toBeEnabled();
    expect(sessionStorage.getItem(key)).toBeNull();
    expect(callEdgeFunction).not.toHaveBeenCalled();
  });

  it('rejects a stored save that points at another endpoint or routine', async () => {
    callEdgeFunction.mockRejectedValueOnce(new FamilyOpsApiError('RESULT_UNKNOWN', '通信が途切れました', 0, undefined, 'unknown'));
    render(<RoutineRoleEditor />);
    let sheet = await openRoutine('お風呂');
    fireEvent.change(within(sheet).getByLabelText('名前'), { target: { value: '保存途中の名前' } });
    fireEvent.click(within(sheet).getByRole('button', { name: '保存' }));
    await screen.findByRole('alert');
    const key = 'family-ops:routine-save:v1:hh-1::bath';
    const plan = JSON.parse(sessionStorage.getItem(key)!);
    sessionStorage.setItem('family-ops:routine-save:v1:hh-1::cold', JSON.stringify(plan));
    plan.steps[0].endpoint = 'accept-request';
    sessionStorage.setItem(key, JSON.stringify(plan));
    fireEvent.click(within(sheet).getByRole('button', { name: 'やめる' }));
    sheet = await openRoutine('お風呂');
    expect(within(sheet).getByLabelText('名前')).toHaveValue('お風呂');
    expect(within(sheet).getByLabelText('名前')).toBeEnabled();
    sheet = await openRoutine('詩乃（風邪）の薬');
    expect(within(sheet).getByLabelText('名前')).toHaveValue('詩乃（風邪）の薬');
    expect(within(sheet).getByLabelText('名前')).toBeEnabled();
    expect(callEdgeFunction).toHaveBeenCalledTimes(1);
  });

  it('keeps an in-flight save for retry without issuing later mutations after unmount', async () => {
    let resolveCreate!: (result: { task_definition_id: string }) => void;
    callEdgeFunction.mockReturnValueOnce(new Promise((resolve) => { resolveCreate = resolve; }));
    const view = render(<RoutineRoleEditor />);
    fireEvent.click(await screen.findByRole('button', { name: '＋ 定例を追加' }));
    const sheet = screen.getByRole('group', { name: '新しい定例の編集' });
    fireEvent.change(within(sheet).getByLabelText('名前'), { target: { value: 'ゴミ出し' } });
    fireEvent.click(within(sheet).getByRole('button', { name: '追加する' }));
    expect(callEdgeFunction).toHaveBeenCalledTimes(1);
    view.unmount();
    await act(async () => { resolveCreate({ task_definition_id: 'new-def' }); });
    expect(callEdgeFunction).toHaveBeenCalledTimes(1);
    expect(JSON.parse(sessionStorage.getItem('family-ops:routine-save:v1:hh-1::new')!)).toEqual(expect.objectContaining({ definitionId: 'new-def', nextStep: 1 }));
  });

  it('does not show or retry another family member\'s in-memory pending save', async () => {
    currentUserId = PAPA;
    callEdgeFunction.mockRejectedValueOnce(new FamilyOpsApiError('RESULT_UNKNOWN', '通信が途切れました', 0, undefined, 'unknown'));
    const view = render(<RoutineRoleEditor />);
    let sheet = await openRoutine('お風呂');
    fireEvent.change(within(sheet).getByLabelText('名前'), { target: { value: 'パパの保存途中の名前' } });
    fireEvent.click(within(sheet).getByRole('button', { name: '保存' }));
    await screen.findByRole('alert');
    currentUserId = MAMA;
    view.rerender(<RoutineRoleEditor />);
    sheet = await openRoutine('お風呂');
    expect(within(sheet).getByLabelText('名前')).toHaveValue('お風呂');
    expect(within(sheet).getByLabelText('名前')).toBeEnabled();
    expect(within(sheet).queryByRole('button', { name: '同じ内容で再試行' })).toBeNull();
    expect(callEdgeFunction).toHaveBeenCalledTimes(1);
    expect(sessionStorage.getItem(`family-ops:routine-save:v1:hh-1:${PAPA}:bath`)).not.toBeNull();
  });

  it('unlocks the editor when the account switches during a save and stops the old follow-up commands', async () => {
    currentUserId = PAPA;
    let resolveCreate!: (result: { task_definition_id: string }) => void;
    callEdgeFunction.mockReturnValueOnce(new Promise((resolve) => { resolveCreate = resolve; }));
    const view = render(<RoutineRoleEditor />);
    fireEvent.click(await screen.findByRole('button', { name: '＋ 定例を追加' }));
    const sheet = screen.getByRole('group', { name: '新しい定例の編集' });
    fireEvent.change(within(sheet).getByLabelText('名前'), { target: { value: 'ゴミ出し' } });
    fireEvent.click(within(sheet).getByRole('button', { name: '追加する' }));
    currentUserId = MAMA;
    view.rerender(<RoutineRoleEditor />);
    expect(await screen.findByRole('button', { name: '＋ 定例を追加' })).toBeEnabled();
    await act(async () => { resolveCreate({ task_definition_id: 'new-def' }); });
    expect(callEdgeFunction).toHaveBeenCalledTimes(1);
    expect(sessionStorage.getItem(`family-ops:routine-save:v1:hh-1:${MAMA}:new`)).toBeNull();
    expect(JSON.parse(sessionStorage.getItem(`family-ops:routine-save:v1:hh-1:${PAPA}:new`)!)).toEqual(expect.objectContaining({ definitionId: 'new-def', nextStep: 1 }));
  });

  it('reloads applied changes for editing after a later save command is definitively rejected', async () => {
    callEdgeFunction.mockResolvedValueOnce({ task_definition_id: 'new-def' });
    callEdgeFunction.mockRejectedValueOnce(new FamilyOpsApiError('INVALID_INPUT', '担当を選び直してください', 400));
    render(<RoutineRoleEditor />);
    fireEvent.click(await screen.findByRole('button', { name: '＋ 定例を追加' }));
    const sheet = screen.getByRole('group', { name: '新しい定例の編集' });
    fireEvent.change(within(sheet).getByLabelText('名前'), { target: { value: 'ゴミ出し' } });
    fireEvent.click(within(sheet).getByRole('button', { name: '追加する' }));
    await screen.findByRole('alert');
    tables.task_definitions.push(def('new-def', 'ゴミ出し'));
    fireEvent.click(within(sheet).getByRole('button', { name: '一覧を確認して編集し直す' }));
    const reloaded = await openRoutine('ゴミ出し');
    expect(within(reloaded).getByLabelText('名前')).toBeEnabled();
    expect(sessionStorage.getItem('family-ops:routine-save:v1:hh-1::new')).toBeNull();
    expect(callEdgeFunction.mock.calls.filter((call) => call[0] === 'create-task-definition')).toHaveLength(1);
    expect(callEdgeFunction).toHaveBeenCalledTimes(2);
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

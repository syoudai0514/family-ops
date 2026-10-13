import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { FamilyOpsApiError } from '../../lib/apiClient';
import { TaskWorkUpdate } from './TaskWorkUpdate';
import type { TaskInstance } from '../../lib/types';
import type { TaskWorkProgressRecord } from '../../lib/taskProgress';

const invoke = vi.fn();
let actorId = 'progress-user';
let historyRows: TaskWorkProgressRecord[] = [];
let historyError: { message: string } | null = null;
vi.mock('../../app/AuthContext', () => ({ useAuth: () => ({ user: { id: actorId } }) }));
vi.mock('../../app/HouseholdContext', () => ({ useHousehold: () => ({ household: { id: 'progress-household' } }) }));
vi.mock('../../lib/apiClient', async () => ({
  ...await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient'),
  callEdgeFunction: (...args: unknown[]) => invoke(...args),
}));
vi.mock('../../lib/supabaseClient', () => ({ supabase: { from: () => {
  const query = { select: () => query, eq: () => query, order: () => query, limit: () => Promise.resolve({ data: historyRows, error: historyError }) };
  return query;
} } }));

const task = { id: 'progress-task', household_id: 'progress-household', title: '食器洗い',
  scheduled_date: '2026-10-12', status: 'todo', revision: 4 } as TaskInstance;

function fill() {
  fireEvent.change(screen.getByLabelText('見つけた状況（任意）'), { target: { value: '昨日の分が未洗浄だった' } });
  fireEvent.change(screen.getByLabelText('自分が行ったこと（任意）'), { target: { value: '朝の食器を追加して洗浄開始' } });
  fireEvent.change(screen.getByLabelText('今の状態・残りの作業（任意）'), { target: { value: '洗浄中。取り出しはまだ' } });
}

describe('task work updates', () => {
  beforeEach(() => { sessionStorage.clear(); actorId = 'progress-user'; historyRows = []; historyError = null; invoke.mockReset(); invoke.mockResolvedValue({ revision: 5 }); });

  it('reopens with the saved body already visible and separates the blank fields for a new entry', async () => {
    historyRows = [{ id: 'saved-note', actor_id: actorId, created_at: '2026-10-13T07:34:20Z',
      payload: { observed_note: '昨日の分が未洗浄だった', work_done_note: '朝の食器を追加して洗浄開始', share_with_household: false } }];
    const { container, unmount } = render(<TaskWorkUpdate task={task} members={[]} currentUserId={actorId} onSaved={() => {}} />);
    await screen.findByText('行ったこと: 朝の食器を追加して洗浄開始');
    expect(container.querySelector('details.task-progress-history')).toHaveAttribute('open');
    expect(screen.getByText('状況メモとして保存（引き継ぎの送信なし）')).toBeVisible();
    expect(screen.getByText('新しく追記する')).toBeVisible();
    expect(screen.getByLabelText('自分が行ったこと（任意）')).toHaveValue('');
    unmount();
    const reopened = render(<TaskWorkUpdate task={task} members={[]} currentUserId={actorId} onSaved={() => {}} />);
    await screen.findByText('見つけた状況: 昨日の分が未洗浄だった');
    expect(reopened.container.querySelector('details.task-progress-history')).toHaveAttribute('open');
    expect(invoke).not.toHaveBeenCalled();
  });

  it('keeps the saved latest note visible when loading older notes fails', async () => {
    historyError = { message: 'offline' };
    const latest = { id: 'saved-note', actor_id: actorId, created_at: '2026-10-13T07:34:20Z', payload: { remaining_note: '取り出しはまだ' } };
    render(<TaskWorkUpdate task={{ ...task, latest_work_progress: [latest] }} members={[]} currentUserId={actorId} onSaved={() => {}} />);
    expect(screen.getByText('今の状態・残り: 取り出しはまだ')).toBeVisible();
    expect(await screen.findByRole('alert')).toHaveTextContent('保存済みの最新メモを表示しています');
    expect(screen.queryByText(/まだ状況メモがありません/)).not.toBeInTheDocument();
  });

  it('records the original task day and ongoing state without a completion or assignment command', async () => {
    const onSaved = vi.fn();
    render(<TaskWorkUpdate task={task} members={[]} currentUserId={actorId} onSaved={onSaved} />);
    fill();
    fireEvent.click(screen.getByRole('button', { name: '記録を保存' }));
    await waitFor(() => expect(onSaved).toHaveBeenCalledOnce());
    expect(invoke).toHaveBeenCalledOnce();
    expect(invoke).toHaveBeenCalledWith('edit-task', expect.objectContaining({
      action: 'record_progress',
      task_id: task.id, expected_revision: 4,
      observed_note: '昨日の分が未洗浄だった', work_done_note: '朝の食器を追加して洗浄開始',
      remaining_note: '洗浄中。取り出しはまだ', share_with_household: false, ack_policy: 'none',
    }));
    expect(screen.getByText(/対象日 2026-10-12/)).toBeInTheDocument();
  });

  it('shares and requests acknowledgement only when the user selects both', async () => {
    render(<TaskWorkUpdate task={task} members={[]} currentUserId={actorId} onSaved={() => {}} />);
    fill();
    fireEvent.change(screen.getByLabelText('次の作業への影響・伝えること（任意）'), { target: { value: '洗浄が終わってから取り出してほしい' } });
    fireEvent.click(screen.getByLabelText('家族に引き継ぎを送る'));
    fireEvent.click(screen.getByLabelText('確認の返答が必要'));
    fireEvent.click(screen.getByRole('button', { name: '記録して引き継ぎを送る' }));
    await waitFor(() => expect(invoke).toHaveBeenCalledOnce());
    expect(invoke.mock.calls[0][1]).toMatchObject({ share_with_household: true, ack_policy: 'required', next_step_note: '洗浄が終わってから取り出してほしい' });
    expect(new Date(invoke.mock.calls[0][1].valid_until).getTime()).toBeGreaterThan(Date.now());
  });

  it('allows an ongoing handover to be kept until explicitly ended', async () => {
    render(<TaskWorkUpdate task={task} members={[]} currentUserId={actorId} onSaved={() => {}} />);
    fill();
    fireEvent.click(screen.getByLabelText('家族に引き継ぎを送る'));
    fireEvent.change(screen.getByLabelText('引き継ぎを表示する期間'), { target: { value: 'manual' } });
    fireEvent.click(screen.getByRole('button', { name: '記録して引き継ぎを送る' }));
    await waitFor(() => expect(invoke).toHaveBeenCalledOnce());
    expect(invoke.mock.calls[0][1]).toMatchObject({ valid_until: null, share_with_household: true, ack_policy: 'none' });
  });

  it('restores an unknown save and retries the same operation and payload after remount', async () => {
    invoke.mockRejectedValueOnce(new FamilyOpsApiError('NETWORK', 'offline', 0, undefined, 'unknown'));
    const props = { task, members: [], currentUserId: actorId, onSaved: vi.fn() };
    const view = render(<TaskWorkUpdate {...props} />);
    fill();
    fireEvent.click(screen.getByRole('button', { name: '記録を保存' }));
    await screen.findByRole('button', { name: 'もう一度確認' });
    const initialPayload = invoke.mock.calls[0][1];
    view.unmount();
    render(<TaskWorkUpdate {...props} task={{ ...task, revision: 5 }} />);
    expect(screen.getByLabelText('自分が行ったこと（任意）')).toHaveValue('朝の食器を追加して洗浄開始');
    expect(screen.getByLabelText('自分が行ったこと（任意）')).toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'もう一度確認' }));
    await waitFor(() => expect(invoke).toHaveBeenCalledTimes(2));
    expect(invoke.mock.calls[1][1]).toEqual(initialPayload);
  });

  it('ignores a late save response after the identity changes', async () => {
    let resolve!: (value: unknown) => void;
    invoke.mockImplementationOnce(() => new Promise(res => { resolve = res; }));
    const onSaved = vi.fn();
    const props = { task, members: [], currentUserId: actorId, onSaved };
    const view = render(<TaskWorkUpdate {...props} />);
    fill();
    fireEvent.click(screen.getByRole('button', { name: '記録を保存' }));
    await waitFor(() => expect(invoke).toHaveBeenCalledOnce());
    actorId = 'other-user';
    view.rerender(<TaskWorkUpdate {...props} currentUserId={actorId} />);
    resolve({ revision: 5 });
    await waitFor(() => expect(screen.getByLabelText('自分が行ったこと（任意）')).toHaveValue(''));
    expect(onSaved).not.toHaveBeenCalled();
  });
});

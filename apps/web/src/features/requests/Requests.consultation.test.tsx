import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { IncomingRequestRow, OutgoingRequestRow } from './Requests';
import { callEdgeFunction } from '../../lib/apiClient';
import type { RequestRow } from '../../lib/types';

vi.mock('../../lib/apiClient', () => ({ callEdgeFunction: vi.fn(), FamilyOpsApiError: class extends Error {} }));
vi.mock('../../lib/useCommandAttempt', () => ({
  useCommandAttempt: () => (
    _key: string, endpoint: Parameters<typeof callEdgeFunction>[0], payload: (operationId: string) => Record<string, unknown>,
  ) => callEdgeFunction(endpoint, payload('operation-test')),
}));

const request = { id: 'request-1', requester_id: 'papa', recipient_id: 'mama', requester_actor_ref_id: 'actor-papa', recipient_actor_ref_id: 'actor-mama', shared_title: 'お迎え', status: 'pending' } as RequestRow;
const attempt = { id: 'attempt-1', request_id: request.id, state: 'awaiting_confirmation' as const, revision: 4, terms_revision: 2, terms: { candidate: '玄関で引き継ぐ' }, request_attempt_confirmations: [{ actor_ref_id: 'actor-mama', terms_revision: 2 }] };

describe('requester consultation from the actual PWA row', () => {
  beforeEach(() => { vi.clearAllMocks(); vi.mocked(callEdgeFunction).mockResolvedValue({ state: 'accepted' }); });

  it('lets the sender confirm the same saved terms revision through the canonical command', async () => {
    const refresh = vi.fn();
    render(<ul><OutgoingRequestRow request={request} attempt={attempt} onChanged={refresh} /></ul>);
    expect(screen.getByDisplayValue('玄関で引き継ぐ')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'この案に同意する' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('negotiate-request', expect.objectContaining({
      request_id: request.id, attempt_id: attempt.id, action: 'confirm_terms', expected_revision: 4, expected_terms_revision: 2,
    })));
    expect(refresh).toHaveBeenCalledOnce();
  });

  it('shows the right spouse their turn and hides duplicate confirmation for that revision', () => {
    const { rerender } = render(<ul><IncomingRequestRow request={request} attempt={attempt} onChanged={vi.fn()} /></ul>);
    expect(screen.getByRole('status')).toHaveTextContent('あなたは同意済みです。相手の返事を待っています。');
    expect(screen.queryByRole('button', { name: 'この案に同意する' })).not.toBeInTheDocument();

    rerender(<ul><IncomingRequestRow request={request} attempt={{
      ...attempt, terms_revision: 3,
      request_attempt_confirmations: [...attempt.request_attempt_confirmations, { actor_ref_id: 'actor-papa', terms_revision: 3 }],
    }} onChanged={vi.fn()} /></ul>);
    expect(screen.getByRole('status')).toHaveTextContent('相手は同意済みです。内容を見て返事をしてください。');
    expect(screen.getByRole('button', { name: 'この案に同意する' })).toBeEnabled();
  });

  it('hides the original reply buttons after starting a consultation and cannot repeat checking', () => {
    const { rerender } = render(<ul><IncomingRequestRow request={request} attempt={{ ...attempt, state: 'pending' }} onChanged={vi.fn()} showOtherFromLink /></ul>);
    expect(screen.getByRole('button', { name: '確認してから返事する' })).toBeInTheDocument();
    rerender(<ul><IncomingRequestRow request={request} attempt={{ ...attempt, state: 'checking' }} onChanged={vi.fn()} showOtherFromLink /></ul>);
    expect(screen.queryByRole('button', { name: '確認してから返事する' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: '相談する' })).toBeInTheDocument();
    rerender(<ul><IncomingRequestRow request={request} attempt={{ ...attempt, state: 'consulting' }} onChanged={vi.fn()} showOtherFromLink /></ul>);
    expect(screen.queryByRole('button', { name: '相談する' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '難しい' })).not.toBeInTheDocument();
    expect(screen.getByText('いまの相談案')).toBeInTheDocument();
  });

  it('shows the accepted work cancellation before asking the recipient for agreement', () => {
    render(<ul><IncomingRequestRow request={{ ...request, status: 'accepted' }} attempt={{
      ...attempt, attempt_kind: 'cancel', terms: { target_task_revision: 3 },
      request_attempt_confirmations: [{ actor_ref_id: 'actor-papa', terms_revision: 2 }],
    }} onChanged={vi.fn()} /></ul>);
    expect(screen.getByText('引き受けた作業を取り消す案')).toBeInTheDocument();
    expect(screen.queryByLabelText('相手へ送る相談文')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: '取り消しに同意する' })).toBeEnabled();
  });

  it('lets the sender stop or confirm withdrawal of the exact attempt', async () => {
    render(<ul><OutgoingRequestRow request={request} attempt={{ ...attempt, state: 'pending' }} onChanged={vi.fn()} /></ul>);
    fireEvent.click(screen.getByRole('button', { name: 'お願いを取り下げる' }));
    expect(callEdgeFunction).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: '戻る' }));
    expect(screen.queryByText('このお願いを取り下げますか？')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'お願いを取り下げる' }));
    fireEvent.click(screen.getByRole('button', { name: '取り下げる' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('cancel-request', expect.objectContaining({
      request_id: request.id, attempt_id: attempt.id, expected_revision: 4, expected_terms_revision: 2,
    })));
  });

  it('cannot confirm unsaved prose as if it were the saved agreement', () => {
    render(<ul><OutgoingRequestRow request={request} attempt={attempt} onChanged={vi.fn()} /></ul>);
    fireEvent.change(screen.getByLabelText('相手へ送る相談文'), { target: { value: '園で引き継ぐ' } });
    const confirm = screen.getByRole('button', { name: 'この案に同意する' });
    expect((confirm as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(confirm);
    expect(callEdgeFunction).not.toHaveBeenCalled();
  });

  it('sends work-date changes only as an explicit structured material patch', async () => {
    render(<ul><OutgoingRequestRow request={request} attempt={attempt} onChanged={vi.fn()} /></ul>);
    fireEvent.change(screen.getByLabelText('変更後の作業期限（任意）'), { target: { value: '2026-09-11T18:30' } });
    fireEvent.click(screen.getByRole('button', { name: '相談案を送る' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('negotiate-request', expect.objectContaining({
      request_id: request.id,
      attempt_id: attempt.id,
      action: 'edit_terms',
      expected_revision: 4,
      expected_terms_revision: 2,
      terms: expect.objectContaining({
        candidate: '玄関で引き継ぐ',
        material_patch: expect.objectContaining({
          version: 1,
          work_due_at: '2026-09-11T09:30:00.000Z',
          scheduled_date: '2026-09-11',
        }),
      }),
    })));
  });
});

it('keeps feelings private, previews the AI wording, and shares only the reviewed proposal', async () => {
  vi.mocked(callEdgeFunction).mockReset();
  vi.mocked(callEdgeFunction).mockResolvedValue({ proposed_text: '今日は帰宅が遅いので、時間を調整できると助かります。' });
  render(<ul><OutgoingRequestRow request={request} attempt={attempt} onChanged={vi.fn()} /></ul>);
  fireEvent.change(screen.getByLabelText('気持ちや事情のメモ（相手には送りません）'), { target: { value: '私ばかりで腹が立つ。今日は帰宅が遅い' } });
  fireEvent.click(screen.getByRole('button', { name: 'AIで相談文を作る' }));
  expect(await screen.findByDisplayValue('今日は帰宅が遅いので、時間を調整できると助かります。')).toBeInTheDocument();
  expect(callEdgeFunction).toHaveBeenCalledTimes(1);
  expect(vi.mocked(callEdgeFunction).mock.calls[0][0]).toBe('propose-ai-draft');
  expect(vi.mocked(callEdgeFunction).mock.calls[0][1]).toEqual(expect.objectContaining({ target_type: 'consultation' }));
  expect(screen.getByLabelText('相手へ送る相談文').tagName).toBe('TEXTAREA');
  fireEvent.change(screen.getByLabelText('相手へ送る相談文'), { target: { value: '今日は帰宅が遅いです。\n18時30分なら対応できます。' } });
  fireEvent.click(screen.getByRole('button', { name: '相談案を送る' }));
  await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(2));
  const shared = vi.mocked(callEdgeFunction).mock.calls[1];
  expect(shared[0]).toBe('negotiate-request');
  expect(JSON.stringify(shared[1])).not.toContain('腹が立つ');
  expect((shared[1] as Record<string,unknown>).terms).toEqual(expect.objectContaining({ candidate: '今日は帰宅が遅いです。\n18時30分なら対応できます。' }));
});

it('keeps unsent feelings private when AI is unavailable', async () => {
  vi.mocked(callEdgeFunction).mockReset();
  vi.mocked(callEdgeFunction).mockRejectedValueOnce(new Error('AI unavailable'));
  render(<ul><OutgoingRequestRow request={request} attempt={attempt} onChanged={vi.fn()} /></ul>);
  fireEvent.change(screen.getByLabelText('気持ちや事情のメモ（相手には送りません）'), { target: { value: '送らない気持ち' } });
  fireEvent.click(screen.getByRole('button', { name: 'AIで相談文を作る' }));
  expect(await screen.findByRole('alert')).toBeInTheDocument();
  expect(screen.getByDisplayValue('玄関で引き継ぐ')).toBeInTheDocument();
  expect(vi.mocked(callEdgeFunction).mock.calls.every(([name]) => name !== 'negotiate-request')).toBe(true);
});

it('lets the recipient decline without a reason after confirming the exact consultation', async () => {
  vi.mocked(callEdgeFunction).mockClear();
  vi.mocked(callEdgeFunction).mockResolvedValue({ state: 'declined' });
  render(<ul><IncomingRequestRow request={request} attempt={attempt} onChanged={vi.fn()} /></ul>);
  fireEvent.click(screen.getByRole('button', { name: '今回は難しい' }));
  expect(callEdgeFunction).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: '難しいと伝える' }));
  await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('negotiate-request', expect.objectContaining({
    request_id: request.id, attempt_id: attempt.id, action: 'decline_consultation', expected_revision: 4, expected_terms_revision: 2,
  })));
});

it('allows only the other party to decline an accepted-task change', () => {
  const change = { ...attempt, attempt_kind: 'change' as const, created_by_actor_ref_id: 'actor-papa' };
  const { rerender } = render(<ul><OutgoingRequestRow request={request} attempt={change} onChanged={vi.fn()} /></ul>);
  expect(screen.queryByRole('button', { name: 'この案を見送る' })).not.toBeInTheDocument();
  rerender(<ul><IncomingRequestRow request={request} attempt={change} onChanged={vi.fn()} /></ul>);
  fireEvent.click(screen.getByRole('button', { name: 'この案を見送る' }));
  expect(screen.getByText('この案を見送りますか？ 元の約束はそのままです。')).toBeInTheDocument();
});

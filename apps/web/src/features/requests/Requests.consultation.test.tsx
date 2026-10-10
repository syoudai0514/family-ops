import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { OutgoingRequestRow } from './Requests';
import { callEdgeFunction } from '../../lib/apiClient';
import type { RequestRow } from '../../lib/types';

vi.mock('../../lib/apiClient', () => ({ callEdgeFunction: vi.fn(), FamilyOpsApiError: class extends Error {} }));

const request = { id: 'request-1', requester_id: 'papa', recipient_id: 'mama', shared_title: 'お迎え', status: 'pending' } as RequestRow;
const attempt = { id: 'attempt-1', request_id: request.id, state: 'awaiting_confirmation' as const, revision: 4, terms_revision: 2, terms: { candidate: '玄関で引き継ぐ' } };

describe('requester consultation from the actual PWA row', () => {
  beforeEach(() => { vi.clearAllMocks(); vi.mocked(callEdgeFunction).mockResolvedValue({ state: 'accepted' }); });

  it('lets the sender confirm the same saved terms revision through the canonical command', async () => {
    const refresh = vi.fn();
    render(<ul><OutgoingRequestRow request={request} attempt={attempt} onChanged={refresh} /></ul>);
    expect(screen.getByDisplayValue('玄関で引き継ぐ')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'この変更案を確認する' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('negotiate-request', expect.objectContaining({
      request_id: request.id, attempt_id: attempt.id, action: 'confirm_terms', expected_revision: 4, expected_terms_revision: 2,
    })));
    expect(refresh).toHaveBeenCalledOnce();
  });

  it('cannot confirm unsaved prose as if it were the saved agreement', () => {
    render(<ul><OutgoingRequestRow request={request} attempt={attempt} onChanged={vi.fn()} /></ul>);
    fireEvent.change(screen.getByLabelText('相談メモ'), { target: { value: '園で引き継ぐ' } });
    const confirm = screen.getByRole('button', { name: 'この変更案を確認する' });
    expect((confirm as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(confirm);
    expect(callEdgeFunction).not.toHaveBeenCalled();
  });

  it('sends work-date changes only as an explicit structured material patch', async () => {
    render(<ul><OutgoingRequestRow request={request} attempt={attempt} onChanged={vi.fn()} /></ul>);
    fireEvent.change(screen.getByLabelText('変更後の作業期限'), { target: { value: '2026-09-11T18:30' } });
    fireEvent.click(screen.getByRole('button', { name: 'この文面・条件で提案する' }));
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
          work_due_at: expect.any(String),
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
  fireEvent.change(screen.getByLabelText('まずは気持ちも含めて入力（相手には送りません）'), { target: { value: '私ばかりで腹が立つ。今日は帰宅が遅い' } });
  fireEvent.click(screen.getByRole('button', { name: 'AIで揉めにくい伝え方を考える' }));
  expect(await screen.findByDisplayValue('今日は帰宅が遅いので、時間を調整できると助かります。')).toBeInTheDocument();
  expect(callEdgeFunction).toHaveBeenCalledTimes(1);
  expect(vi.mocked(callEdgeFunction).mock.calls[0][0]).toBe('propose-ai-draft');
  fireEvent.click(screen.getByRole('button', { name: 'この文面・条件で提案する' }));
  await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(2));
  const shared = vi.mocked(callEdgeFunction).mock.calls[1];
  expect(shared[0]).toBe('negotiate-request');
  expect(JSON.stringify(shared[1])).not.toContain('腹が立つ');
  expect((shared[1] as Record<string,unknown>).terms).toEqual(expect.objectContaining({ candidate: '今日は帰宅が遅いので、時間を調整できると助かります。' }));
});

it('keeps unsent feelings private when AI is unavailable', async () => {
  vi.mocked(callEdgeFunction).mockReset();
  vi.mocked(callEdgeFunction).mockRejectedValueOnce(new Error('AI unavailable'));
  render(<ul><OutgoingRequestRow request={request} attempt={attempt} onChanged={vi.fn()} /></ul>);
  fireEvent.change(screen.getByLabelText('まずは気持ちも含めて入力（相手には送りません）'), { target: { value: '送らない気持ち' } });
  fireEvent.click(screen.getByRole('button', { name: 'AIで揉めにくい伝え方を考える' }));
  expect(await screen.findByRole('alert')).toBeInTheDocument();
  expect(screen.getByDisplayValue('玄関で引き継ぐ')).toBeInTheDocument();
  expect(vi.mocked(callEdgeFunction).mock.calls.every(([name]) => name !== 'negotiate-request')).toBe(true);
});

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
    fireEvent.click(screen.getByRole('button', { name: '表示中の条件版を確認する' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('negotiate-request', expect.objectContaining({
      request_id: request.id, attempt_id: attempt.id, action: 'confirm_terms', expected_revision: 4, expected_terms_revision: 2,
    })));
    expect(refresh).toHaveBeenCalledOnce();
  });

  it('cannot confirm unsaved prose as if it were the saved agreement', () => {
    render(<ul><OutgoingRequestRow request={request} attempt={attempt} onChanged={vi.fn()} /></ul>);
    fireEvent.change(screen.getByLabelText('相談メモ'), { target: { value: '園で引き継ぐ' } });
    const confirm = screen.getByRole('button', { name: '表示中の条件版を確認する' });
    expect((confirm as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(confirm);
    expect(callEdgeFunction).not.toHaveBeenCalled();
  });

  it('sends work-date changes only as an explicit structured material patch', async () => {
    render(<ul><OutgoingRequestRow request={request} attempt={attempt} onChanged={vi.fn()} /></ul>);
    fireEvent.change(screen.getByLabelText('変更後の作業期限'), { target: { value: '2026-09-11T18:30' } });
    fireEvent.click(screen.getByRole('button', { name: '具体条件を提案' }));
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

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

  it('lets the sender confirm the same terms revision after the recipient, through the canonical command', async () => {
    const refresh = vi.fn();
    render(<ul><OutgoingRequestRow request={request} attempt={attempt} onChanged={refresh} /></ul>);
    expect(screen.getByDisplayValue('玄関で引き継ぐ')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'この条件で確認する' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('negotiate-request', expect.objectContaining({
      request_id: request.id, attempt_id: attempt.id, action: 'confirm_terms', expected_revision: 4, expected_terms_revision: 2,
    })));
    expect(refresh).toHaveBeenCalledOnce();
  });

  it('cannot confirm unsent edited text as if it were the saved agreement', () => {
    render(<ul><OutgoingRequestRow request={request} attempt={attempt} onChanged={vi.fn()} /></ul>);
    fireEvent.change(screen.getByLabelText('合意する条件'), { target: { value: '園で引き継ぐ' } });
    fireEvent.click(screen.getByRole('button', { name: 'この条件で確認する' }));
    expect(callEdgeFunction).not.toHaveBeenCalled();
    expect((screen.getByRole('button', { name: 'この条件で確認する' }) as HTMLButtonElement).disabled).toBe(true);
  });
});

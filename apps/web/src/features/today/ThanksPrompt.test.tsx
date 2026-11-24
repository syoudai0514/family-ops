import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ThanksPrompt } from './ThanksPrompt';

const read = vi.fn();
const send = vi.fn();
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ household: { id: 'h' }, members: [{ user_id: 'm', family_role: 'mama' }] }),
}));
vi.mock('../../lib/apiClient', () => ({ callEdgeFunction: (...args: unknown[]) => read(...args) }));
vi.mock('../../lib/useCommandAttempt', () => ({
  useCommandAttempt: () => (_key: string, _endpoint: string, payload: (id: string) => unknown) => send(payload('operation')),
}));

describe('thanks', () => {
  beforeEach(() => {
    read.mockReset();
    send.mockReset();
    read.mockResolvedValue([{ kind: 'task', id: 'task', title: 'お迎え', recipient_id: 'm' }]);
    send.mockResolvedValue({ sent: true });
  });

  it('lets the user add their own short note', async () => {
    render(<ThanksPrompt refreshKey="ready" />);
    await screen.findByText('ママが「お迎え」を代わってくれました');
    fireEvent.click(screen.getByText('ひとこと添える'));
    fireEvent.change(screen.getByLabelText('メッセージ'), { target: { value: '助かったよ' } });
    fireEvent.click(screen.getByRole('button', { name: '添えて送る' }));
    await waitFor(() => expect(send).toHaveBeenCalledWith(expect.objectContaining({ note: '助かったよ' })));
  });

  it('shows sent on the same dated row, even when a stale refresh returns it', async () => {
    const candidate = { kind: 'request', id: 'pickup', title: 'お迎え', recipient_id: 'm', activity_date: '2026-11-24', target_date: '2026-11-25' };
    const other = { ...candidate, id: 'pickup-later', target_date: '2026-11-26' };
    read.mockResolvedValue([candidate, other]);
    const { rerender } = render(<ThanksPrompt refreshKey="ready" />);
    const row = (await screen.findByText('11月25日')).closest('.thanks-item') as HTMLElement;
    const secondRow = screen.getByText('11月26日').closest('.thanks-item') as HTMLElement;
    expect(secondRow.closest('details')).not.toHaveAttribute('open');
    expect(send).not.toHaveBeenCalled();
    fireEvent.click(within(row).getByRole('button', { name: 'ありがとうを送る' }));
    await waitFor(() => expect(send).toHaveBeenCalledWith(expect.objectContaining({
      action: 'send_thanks', source_kind: 'request', source_id: 'pickup',
    })));
    expect(await within(row).findByRole('status')).toHaveTextContent('送信済み');
    rerender(<ThanksPrompt refreshKey="refresh" />);
    await waitFor(() => expect(read).toHaveBeenCalledTimes(2));
    expect(within(row).getByRole('status')).toHaveTextContent('送信済み');
    expect(within(row).queryByRole('button', { name: 'ありがとうを送る' })).not.toBeInTheDocument();
    expect(secondRow.querySelector('button')).toHaveTextContent('ありがとうを送る');
  });
});

import { fireEvent, render, screen, waitFor } from '@testing-library/react';
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

  it('sends only after the user presses the button and removes the invitation after success', async () => {
    render(<ThanksPrompt refreshKey="ready" />);
    expect(await screen.findByText('ママが「お迎え」を代わってくれました')).toBeInTheDocument();
    expect(send).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'ありがとうを送る' }));
    await waitFor(() => expect(send).toHaveBeenCalledWith(expect.objectContaining({
      action: 'send_thanks', source_kind: 'task', source_id: 'task',
    })));
    expect(await screen.findByText('ありがとうを送りました。')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'ありがとうを送る' })).not.toBeInTheDocument();
  });
});

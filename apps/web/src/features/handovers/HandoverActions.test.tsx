import { describe, expect, it, vi, beforeEach } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { HandoverActions } from './HandoverActions';

const runCommand = vi.fn();
vi.mock('../../lib/useCommandAttempt', () => ({ useCommandAttempt: () => runCommand }));

const handover = { id: 'h1', author_id: 'papa', ack_policy: 'none' as const };

describe('HandoverActions', () => {
  beforeEach(() => {
    runCommand.mockReset();
    runCommand.mockResolvedValue({ ok: true });
  });

  // Live 2026-09-30: the Today card had no button, so a note stayed "未読" for weeks.
  it('lets the reader mark a note 確認した', async () => {
    const onChanged = vi.fn();
    render(<HandoverActions handover={handover} currentUserId="mama" isRead={false} onChanged={onChanged} />);
    fireEvent.click(screen.getByRole('button', { name: '確認した' }));
    await waitFor(() => expect(onChanged).toHaveBeenCalled());
    expect(runCommand.mock.calls[0][1]).toBe('mark-handover-read');
    expect(runCommand.mock.calls[0][2]('op-1')).toEqual({ operation_id: 'op-1', handover_id: 'h1' });
  });

  // Owner decision 2026-09-30: any adult can clear a note, not only its author.
  it('lets the reader end it for everyone too', async () => {
    const onChanged = vi.fn();
    render(<HandoverActions handover={handover} currentUserId="mama" isRead={false} onChanged={onChanged} />);
    fireEvent.click(screen.getByRole('button', { name: 'この共有を終える' }));
    fireEvent.click(screen.getByRole('button', { name: '終える' }));
    await waitFor(() => expect(onChanged).toHaveBeenCalled());
    expect(runCommand.mock.calls[0][1]).toBe('end-handover');
  });

  it('lets the author end it, with one confirmation step', async () => {
    const onChanged = vi.fn();
    render(<HandoverActions handover={handover} currentUserId="papa" isRead={false} onChanged={onChanged} />);
    expect(screen.getByText('あなたが共有中')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '確認した' })).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'この共有を終える' }));
    expect(runCommand).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: '終える' }));
    await waitFor(() => expect(onChanged).toHaveBeenCalled());
    expect(runCommand.mock.calls[0][1]).toBe('end-handover');
  });

  it('やめる cancels ending without a command', () => {
    render(<HandoverActions handover={handover} currentUserId="papa" isRead={false} onChanged={vi.fn()} />);
    fireEvent.click(screen.getByRole('button', { name: 'この共有を終える' }));
    fireEvent.click(screen.getByRole('button', { name: 'やめる' }));
    expect(runCommand).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: 'この共有を終える' })).toBeInTheDocument();
  });
});

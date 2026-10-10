import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { AssignmentPreview } from './AssignmentPreview';
import { callEdgeFunction } from '../../lib/apiClient';

vi.mock('../../lib/apiClient', () => ({ callEdgeFunction: vi.fn() }));
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({
    members: [
      { user_id: 'mama', family_role: 'mama' },
      { user_id: 'papa', family_role: 'papa' },
    ],
  }),
}));

const current = {
  revision: 4,
  terms_revision: 2,
  stale: false,
  targets: [
    {
      id: 'pickup',
      title: 'お迎え',
      date: '2026-10-12',
      due_at: null,
      from_user_id: 'mama',
      to_user_id: 'papa',
    },
  ],
  linked: [
    {
      id: 'laundry',
      title: '洗濯',
      date: '2026-10-12',
      due_at: null,
      from_user_id: 'papa',
      to_user_id: 'mama',
    },
  ],
};

describe('assignment acceptance preview', () => {
  beforeEach(() => vi.mocked(callEdgeFunction).mockReset());

  it('shows both the requested work and affected chores before allowing acceptance', async () => {
    vi.mocked(callEdgeFunction).mockResolvedValue(current);
    const ready = vi.fn();
    render(
      <AssignmentPreview
        requestId="request"
        attemptId="attempt"
        expectedRevision={4}
        expectedTermsRevision={2}
        onReady={ready}
      />,
    );
    expect(await screen.findByText('一緒に変わる当日の家事')).toBeInTheDocument();
    expect(screen.getByText('ママ → パパ')).toBeInTheDocument();
    expect(screen.getByText('パパ → ママ')).toBeInTheDocument();
    expect(ready).toHaveBeenLastCalledWith(true);
    expect(callEdgeFunction).toHaveBeenCalledOnce();
    expect(vi.mocked(callEdgeFunction).mock.calls[0][0]).toBe('complete-onboarding-step');
  });

  it('keeps acceptance disabled when the saved request changed', async () => {
    vi.mocked(callEdgeFunction).mockResolvedValue({ ...current, revision: 5 });
    const ready = vi.fn();
    render(
      <AssignmentPreview
        requestId="request"
        attemptId="attempt"
        expectedRevision={4}
        expectedTermsRevision={2}
        onReady={ready}
      />,
    );
    expect(await screen.findByRole('alert')).toHaveTextContent('家族が先に変更しました');
    expect(ready).not.toHaveBeenCalledWith(true);
  });

  it('retries a failed read without issuing an accept command', async () => {
    vi.mocked(callEdgeFunction)
      .mockRejectedValueOnce(new Error('通信失敗'))
      .mockResolvedValueOnce(current);
    const ready = vi.fn();
    render(
      <AssignmentPreview
        requestId="request"
        attemptId="attempt"
        expectedRevision={4}
        expectedTermsRevision={2}
        onReady={ready}
      />,
    );
    fireEvent.click(await screen.findByRole('button', { name: '再確認' }));
    await waitFor(() => expect(ready).toHaveBeenLastCalledWith(true));
    expect(vi.mocked(callEdgeFunction).mock.calls.every(([name]) => name === 'complete-onboarding-step')).toBe(
      true,
    );
  });

  it('does not allow an older delayed response to unlock revised terms', async () => {
    let resolveOld!: (value: typeof current) => void;
    vi.mocked(callEdgeFunction).mockReturnValueOnce(
      new Promise((resolve) => {
        resolveOld = resolve;
      }),
    );
    vi.mocked(callEdgeFunction).mockResolvedValueOnce({ ...current, revision: 5, stale: true });
    const ready = vi.fn();
    const view = render(
      <AssignmentPreview
        requestId="request"
        attemptId="attempt"
        expectedRevision={4}
        expectedTermsRevision={2}
        onReady={ready}
      />,
    );
    view.rerender(
      <AssignmentPreview
        requestId="request"
        attemptId="attempt"
        expectedRevision={5}
        expectedTermsRevision={2}
        onReady={ready}
      />,
    );
    await screen.findByRole('alert');
    await act(async () => {
      resolveOld(current);
    });
    expect(ready).not.toHaveBeenCalledWith(true);
    expect(screen.getByRole('alert')).toBeInTheDocument();
  });
});

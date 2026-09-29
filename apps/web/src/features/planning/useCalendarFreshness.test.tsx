import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { useCalendarFreshness } from './useCalendarFreshness';

vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return { ...actual, callEdgeFunction: vi.fn() };
});

const mockCallEdgeFunction = vi.mocked(callEdgeFunction);

function Harness({ auto = true }: { auto?: boolean }) {
  const freshness = useCalendarFreshness({ enabled: true, auto });
  return (
    <div>
      <button type="button" onClick={() => void freshness.resync()}>
        sync
      </button>
      <span data-testid="syncing">{freshness.syncing ? 'yes' : 'no'}</span>
      <span data-testid="requested">{freshness.requestedAt ? 'yes' : 'no'}</span>
      {freshness.error && <span role="alert">{freshness.error}</span>}
    </div>
  );
}

describe('useCalendarFreshness', () => {
  beforeEach(() => {
    mockCallEdgeFunction.mockReset();
  });

  it('requests a coalesced refresh once when a calendar view mounts', async () => {
    mockCallEdgeFunction.mockResolvedValue({});

    const view = render(<Harness />);

    await waitFor(() => {
      expect(mockCallEdgeFunction).toHaveBeenCalledTimes(1);
    });
    expect(mockCallEdgeFunction).toHaveBeenCalledWith(EDGE_FUNCTIONS.ensureCalendarFresh, {});
    expect(screen.getByTestId('requested')).toHaveTextContent('yes');

    view.rerender(<Harness />);
    expect(mockCallEdgeFunction).toHaveBeenCalledTimes(1);
  });

  it('supports an explicit retry and exposes a non-blocking error', async () => {
    mockCallEdgeFunction.mockRejectedValueOnce(new Error('offline'));
    render(<Harness auto={false} />);

    fireEvent.click(screen.getByRole('button', { name: 'sync' }));

    expect(screen.getByTestId('syncing')).toHaveTextContent('yes');
    await waitFor(() => {
      expect(screen.getByRole('alert')).toHaveTextContent('Googleカレンダーの再同期を開始できませんでした。');
    });
    expect(screen.getByTestId('syncing')).toHaveTextContent('no');

    mockCallEdgeFunction.mockResolvedValueOnce({});
    fireEvent.click(screen.getByRole('button', { name: 'sync' }));

    await waitFor(() => {
      expect(screen.getByTestId('requested')).toHaveTextContent('yes');
    });
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    expect(mockCallEdgeFunction).toHaveBeenLastCalledWith(EDGE_FUNCTIONS.ensureCalendarFresh, {});
  });
});

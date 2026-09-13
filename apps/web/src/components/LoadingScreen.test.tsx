import { act, fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { LoadingScreen } from './LoadingScreen';

describe('LoadingScreen', () => {
  it('offers a manual recovery action when loading takes too long', async () => {
    vi.useFakeTimers();
    const reload = vi.spyOn(window.location, 'reload').mockImplementation(() => undefined);
    render(<LoadingScreen recoveryAfterMs={1_000} />);

    expect(screen.queryByRole('button', { name: '再読み込み' })).not.toBeInTheDocument();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1_000);
    });

    fireEvent.click(screen.getByRole('button', { name: '再読み込み' }));
    expect(reload).toHaveBeenCalledTimes(1);

    reload.mockRestore();
    vi.useRealTimers();
  });
});

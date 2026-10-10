import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { UndoNoticeProvider, useUndoNotice } from './UndoNotice';

function Actions({ firstUndo }: { firstUndo: () => Promise<void> }) {
  const show = useUndoNotice();
  return (
    <>
      <button onClick={() => show({ label: '朝ごはんを記録しました', undo: firstUndo })}>
        朝ごはんを記録
      </button>
      <button
        onClick={() =>
          show({ label: '洗濯を記録しました', undo: vi.fn().mockResolvedValue(undefined) })
        }
      >
        洗濯を記録
      </button>
    </>
  );
}

describe('undo for consecutive records', () => {
  it('retains the newer record when an earlier undo finishes', async () => {
    let finish!: () => void;
    render(
      <UndoNoticeProvider>
        <Actions
          firstUndo={() =>
            new Promise((resolve) => {
              finish = resolve;
            })
          }
        />
      </UndoNoticeProvider>,
    );
    fireEvent.click(screen.getByText('朝ごはんを記録'));
    fireEvent.click(screen.getByText('元に戻す'));
    fireEvent.click(screen.getByText('洗濯を記録'));
    await act(async () => finish());
    expect(screen.getByRole('status')).toHaveTextContent('洗濯を記録しました');
    expect(screen.getByText('元に戻す')).toBeEnabled();
  });

  it('does not attach an earlier undo error to a newer record', async () => {
    let fail!: (error: Error) => void;
    render(
      <UndoNoticeProvider>
        <Actions
          firstUndo={() =>
            new Promise((_, reject) => {
              fail = reject;
            })
          }
        />
      </UndoNoticeProvider>,
    );
    fireEvent.click(screen.getByText('朝ごはんを記録'));
    fireEvent.click(screen.getByText('元に戻す'));
    fireEvent.click(screen.getByText('洗濯を記録'));
    await act(async () => fail(new Error('古い記録の競合')));
    await waitFor(() => expect(screen.getByText('元に戻す')).toBeEnabled());
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    expect(screen.getByRole('status')).toHaveTextContent('洗濯を記録しました');
  });
});

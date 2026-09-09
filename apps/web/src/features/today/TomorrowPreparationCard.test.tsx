import { act, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { TomorrowPreparationCard } from './TomorrowPreparationCard';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';

vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return { ...actual, callEdgeFunction: vi.fn(() => Promise.resolve({})) };
});

describe('TomorrowPreparationCard', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-09-09T05:00:00Z'));
    vi.mocked(callEdgeFunction).mockClear();
  });

  afterEach(() => vi.useRealTimers());

  it('never writes a preparation to the current JST date when the DailyBrief has no tomorrow date yet', async () => {
    render(
      <TomorrowPreparationCard
        tomorrowDate="2026-09-09"
        assigneeId={null}
        assigneeLabel=""
        existingTitles={[]}
        onChanged={vi.fn()}
      />,
    );

    fireEvent.change(screen.getByRole('textbox', { name: '明日の準備' }), { target: { value: '水着' } });
    await act(async () => {
      fireEvent.click(screen.getByRole('button', { name: '明日に追加' }));
      await Promise.resolve();
    });

    expect(callEdgeFunction).toHaveBeenCalledWith(
      EDGE_FUNCTIONS.createHandover,
      expect.objectContaining({ title: '水着', scheduled_date: '2026-09-10' }),
    );
  });
});

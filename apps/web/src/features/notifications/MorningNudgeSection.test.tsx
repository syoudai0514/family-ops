import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { MorningNudgeSection } from './MorningNudgeSection';

const callEdgeFunction = vi.fn();
const refresh = vi.fn();
const household = vi.hoisted(() => ({ value: { id: 'h1', morning_nudge_local_time: '07:30:00' as string | null | undefined } }));

vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ household: household.value, refresh }),
}));
vi.mock('../../lib/apiClient', () => ({
  callEdgeFunction: (...args: unknown[]) => callEdgeFunction(...args),
  FamilyOpsApiError: class extends Error {},
}));

describe('MorningNudgeSection', () => {
  beforeEach(() => {
    callEdgeFunction.mockReset();
    callEdgeFunction.mockResolvedValue({ ok: true });
    refresh.mockReset();
    household.value = { id: 'h1', morning_nudge_local_time: '07:30:00' };
  });

  it('shows the household time and changes it', async () => {
    render(<MorningNudgeSection />);
    const select = screen.getByRole('combobox', { name: 'お知らせの時刻' }) as HTMLSelectElement;
    expect(select.value).toBe('07:30');
    fireEvent.change(select, { target: { value: '08:00' } });
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledOnce());
    expect(callEdgeFunction.mock.calls[0][1]).toMatchObject({ reminder_settings: { morning_nudge_local_time: '08:00' } });
    expect(await screen.findByText(/平日の08:00に/)).toBeInTheDocument();
  });

  it('can be turned off', async () => {
    render(<MorningNudgeSection />);
    fireEvent.change(screen.getByRole('combobox', { name: 'お知らせの時刻' }), { target: { value: '' } });
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledOnce());
    expect(callEdgeFunction.mock.calls[0][1]).toMatchObject({ reminder_settings: { morning_nudge_local_time: null } });
    expect(await screen.findByText(/やめました/)).toBeInTheDocument();
  });

  it('reads an off household as off and an unread column as the default', () => {
    household.value = { id: 'h1', morning_nudge_local_time: null };
    const { unmount } = render(<MorningNudgeSection />);
    expect((screen.getByRole('combobox') as HTMLSelectElement).value).toBe('');
    unmount();
    household.value = { id: 'h1', morning_nudge_local_time: undefined };
    render(<MorningNudgeSection />);
    expect((screen.getByRole('combobox') as HTMLSelectElement).value).toBe('07:30');
  });
});

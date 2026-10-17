import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ReminderSettingsSection } from './ReminderSettingsSection';

const callEdgeFunction = vi.fn();
const refresh = vi.fn();
const household = vi.hoisted(() => ({ value: { id: 'h1', default_timed_reminders: [60], default_all_day_reminders: [780] } }));

vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ household: household.value, me: { user_id: 'u1' }, refresh }),
}));
vi.mock('../../lib/apiClient', () => ({
  callEdgeFunction: (...args: unknown[]) => callEdgeFunction(...args),
  FamilyOpsApiError: class extends Error {},
}));
vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: () => ({
      select: () => ({ eq: () => ({ eq: () => ({ maybeSingle: () => Promise.resolve({ data: { schedule_line_with_push: false } }) }) }) }),
    }),
  },
}));

describe('ReminderSettingsSection', () => {
  beforeEach(() => {
    callEdgeFunction.mockReset();
    callEdgeFunction.mockResolvedValue({ ok: true });
    refresh.mockReset();
  });

  it('changes the family default for timed schedules', async () => {
    render(<ReminderSettingsSection />);
    const timed = screen.getByRole('group', { name: '時刻のある予定' });
    fireEvent.click(timed.querySelector('input[type="checkbox"]:not(:checked)')!); // 開始時
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledOnce());
    expect(callEdgeFunction.mock.calls[0][1]).toMatchObject({ reminder_settings: { default_timed_reminders: [0, 60] } });
    expect(refresh).toHaveBeenCalled();
  });

  it('lets a person also receive reminders by LINE when push is on', async () => {
    render(<ReminderSettingsSection />);
    const toggle = await screen.findByRole('checkbox', { name: /LINEでも受け取る/ });
    fireEvent.click(toggle);
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledOnce());
    expect(callEdgeFunction.mock.calls[0][1]).toMatchObject({ reminder_settings: { schedule_line_with_push: true } });
    expect(await screen.findByText(/LINEでも受け取ります/)).toBeInTheDocument();
  });
});

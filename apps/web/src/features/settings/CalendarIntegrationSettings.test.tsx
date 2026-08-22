import { render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { CalendarIntegrationSettings } from './CalendarIntegrationSettings';

const fixtures = vi.hoisted(() => ({ rows: [] as Record<string, unknown>[] }));
const builder = () => {
  const query = {
    select: vi.fn(() => query),
    eq: vi.fn(() => query),
    then: (resolve: (result: { data: Record<string, unknown>[]; error: null }) => unknown) =>
      Promise.resolve({ data: fixtures.rows, error: null }).then(resolve),
  };
  return query;
};

vi.mock('../../app/HouseholdContext', () => ({ useHousehold: () => ({ household: { id: 'household-1' } }) }));
vi.mock('../../lib/supabaseClient', () => ({ supabase: { from: vi.fn(() => builder()) } }));
vi.mock('../../lib/apiClient', () => ({ callEdgeFunction: vi.fn() }));
vi.mock('../../lib/edgeFunctions', () => ({ EDGE_FUNCTIONS: { googleCalendarOauthStart: 'google-calendar-oauth-start', setFamilyCalendarTarget: 'set-family-calendar-target' } }));
vi.mock('../../lib/id', () => ({ newOperationId: () => 'operation-id' }));

describe('CalendarIntegrationSettings', () => {
  beforeEach(() => {
    fixtures.rows = [
      { id: 'primary', external_calendar_id: 'primary@example.com', display_name: 'Personal', active: true, reauth_required: false, is_family_write_target: false },
      { id: 'shared', external_calendar_id: 'shared@example.com', display_name: 'Family calendar', active: true, reauth_required: false, is_family_write_target: false },
    ];
    window.history.replaceState({}, '', '/settings');
  });

  it('shows every OAuth candidate and makes an unselected write target explicit', async () => {
    render(<CalendarIntegrationSettings />);
    expect(await screen.findByLabelText(/Personal/)).toBeInTheDocument();
    expect(screen.getByLabelText(/Family calendar/)).toBeInTheDocument();
    expect(screen.getByText('家族予定を書き込むカレンダーを選んでください')).toBeInTheDocument();
  });

  it('explains an OAuth callback error on the existing Settings route', async () => {
    window.history.replaceState({}, '', '/settings?google_calendar_error=access_denied');
    render(<CalendarIntegrationSettings />);
    expect(await screen.findByText('Google Calendarの接続を完了できませんでした。もう一度お試しください。')).toBeInTheDocument();
  });
});

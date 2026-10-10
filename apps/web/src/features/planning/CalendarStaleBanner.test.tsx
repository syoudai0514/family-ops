import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { CalendarStaleBanner } from './CalendarStaleBanner';

const fixtures = vi.hoisted(() => ({ rows: [] as Record<string, unknown>[] }));
const callEdgeFunction = vi.hoisted(() => vi.fn());
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
vi.mock('../../lib/apiClient', () => ({ callEdgeFunction }));

const freshness = { syncing: false, error: null, requestedAt: null, resync: vi.fn(async () => true) } as never;

describe('CalendarStaleBanner', () => {
  beforeEach(() => { callEdgeFunction.mockReset(); });

  it('offers a reconnect, not a re-sync, when Google withdrew the permission', async () => {
    fixtures.rows = [{ active: true, reauth_required: true }];
    callEdgeFunction.mockResolvedValue({ authorization_url: 'https://accounts.example/auth' });
    const assign = vi.fn();
    Object.defineProperty(window, 'location', { value: { ...window.location, assign }, configurable: true });
    render(<CalendarStaleBanner freshness={freshness} onSynced={vi.fn()} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Googleカレンダーを再接続' }));
    expect(screen.getByText('Googleカレンダーとの接続が切れています')).toBeInTheDocument();
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('google-calendar-oauth-start', { return_to: '/week' }));
    expect(assign).toHaveBeenCalledWith('https://accounts.example/auth');
  });

  it('keeps the re-sync action while the connection itself is healthy', async () => {
    fixtures.rows = [{ active: true, reauth_required: false }];
    render(<CalendarStaleBanner freshness={freshness} onSynced={vi.fn()} />);
    expect(await screen.findByRole('button', { name: '今すぐ同期する' })).toBeInTheDocument();
    expect(screen.queryByText('Googleカレンダーとの接続が切れています')).not.toBeInTheDocument();
  });
});

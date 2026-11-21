import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { createSupabaseFromMock } from '../../test/supabaseMock';
import { ThanksHistory } from './ThanksHistory';

vi.mock('../../lib/supabaseClient', () => ({
  supabase: { from: createSupabaseFromMock({ user_notifications: [{ id: 'n1', created_at: '2026-11-20T03:00:00Z', body: 'private message' }] }) },
}));

describe('received thanks history', () => {
  it('shows the fact and time without the message', async () => {
    render(<ThanksHistory householdId="h" userId="u" start="2026-11-01" end="2026-11-21" />);
    expect(await screen.findByText(/ありがとうが届いた/)).toBeInTheDocument();
    expect(screen.queryByText('private message')).not.toBeInTheDocument();
  });
});

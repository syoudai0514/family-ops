import { fireEvent, render, screen, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';

import { Requests } from './Requests';

vi.mock('../../app/AuthContext', () => ({ useAuth: () => ({ user: { id: 'me' } }) }));
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ household: { id: 'family' }, partner: { user_id: 'partner' } }),
}));
vi.mock('../../lib/supabaseClient', async () => {
  const { createSupabaseFromMock } = await import('../../test/supabaseMock');
  return {
    supabase: {
      from: createSupabaseFromMock({
        requests: [
          { id: 'other', recipient_id: 'me', requester_id: 'partner', shared_title: '洗濯', status: 'pending' },
          { id: 'active', recipient_id: 'me', requester_id: 'partner', shared_title: 'お迎え', status: 'pending' },
          { id: 'expired', recipient_id: 'me', requester_id: 'partner', shared_title: '布団の準備', status: 'cancelled' },
          { id: 'accepted', recipient_id: 'partner', requester_id: 'me', shared_title: '買い物', status: 'accepted' },
        ],
        request_attempts: [
          { id: 'a-other', request_id: 'other', state: 'pending' },
          { id: 'a-active', request_id: 'active', state: 'pending' },
          { id: 'a-expired', request_id: 'expired', state: 'expired' },
          { id: 'a-accepted', request_id: 'accepted', state: 'accepted' },
        ],
      }),
    },
  };
});
vi.mock('../../lib/useCommandAttempt', () => ({ useCommandAttempt: () => vi.fn() }));

function renderLink(search: string) {
  return render(<MemoryRouter initialEntries={[`/requests?${search}`]}><Requests /></MemoryRouter>);
}

describe('request links', () => {
  it('focuses and opens other responses only for the linked incoming request', async () => {
    renderLink('request=active&response=other&bucket=history');
    const row = (await screen.findByText('お迎え')).closest('li')!;
    const otherRow = screen.getByText('洗濯').closest('li')!;
    expect(row).toHaveFocus();
    expect(within(row).getByRole('button', { name: '相談する' })).toBeInTheDocument();
    expect(within(otherRow).queryByRole('button', { name: '相談する' })).not.toBeInTheDocument();
  });

  it.each([
    ['expired', '布団の準備', '期限切れ 1'],
    ['accepted', '買い物', '履歴 1'],
  ])('opens the current bucket when the linked request is %s', async (id, title, bucket) => {
    renderLink(`request=${id}&response=other`);
    const row = (await screen.findByText(title)).closest('li')!;
    expect(row).toHaveFocus();
    expect(screen.getByRole('button', { name: bucket })).toHaveAttribute('aria-pressed', 'true');
    expect(within(row).queryByRole('button', { name: 'その他の返答' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '対応中 2' }));
    expect(screen.getByText('お迎え')).toBeInTheDocument();
    expect(screen.queryByText(title)).not.toBeInTheDocument();
  });

  it('shows a missing-request message rather than opening a different row', async () => {
    renderLink('request=unknown&response=other');
    expect(await screen.findByRole('status')).toHaveTextContent('このお願いは見つかりませんでした。');
    expect(screen.queryByRole('button', { name: '相談する' })).not.toBeInTheDocument();
  });
});

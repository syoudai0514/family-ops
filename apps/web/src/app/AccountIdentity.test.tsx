import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { AccountChip, LinkRecipientBanner } from './AccountIdentity';

const signOut = vi.fn().mockResolvedValue({ error: null });
vi.mock('../lib/supabaseClient', () => ({ supabase: { auth: { signOut: () => signOut() } } }));
vi.mock('./AuthContext', () => ({ useAuth: () => ({ user: { id: 'mama-id' } }) }));
vi.mock('./HouseholdContext', () => ({
  useHousehold: () => ({
    members: [
      { user_id: 'papa-id', family_role: 'papa', profile: { display_name: 'パパ' } },
      { user_id: 'mama-id', family_role: 'mama', profile: { display_name: 'ママ（仮）' } },
    ],
  }),
}));

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AccountChip />
      <LinkRecipientBanner />
    </MemoryRouter>,
  );
}

describe('account identity', () => {
  it('always shows who is signed in', () => {
    renderAt('/today');
    expect(screen.getByRole('link', { name: 'ママとしてログイン中（設定）' })).toHaveTextContent('ママ');
  });

  // Live 2026-09-30: papa's LINE link opened a browser signed in as mama.
  it('warns when a LINE link was sent to the other parent, and offers the switch', () => {
    renderAt('/today?for=papa-id');
    expect(screen.getByRole('alert')).toHaveTextContent('このLINEのリンクはパパ宛てですが、いまはママでログインしています。');
    screen.getByRole('button', { name: 'ログアウトしてパパでログイン' }).click();
    expect(signOut).toHaveBeenCalled();
  });

  it('stays quiet for the right person or an unknown id', () => {
    renderAt('/today?for=mama-id');
    expect(screen.queryByRole('alert')).toBeNull();
  });
});

import { render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import App from './App';

const authState = vi.hoisted(() => ({ session: null as { user: { id: string } } | null }));

vi.mock('./lib/supabaseClient', () => ({
  supabase: {
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: authState.session } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
}));

vi.mock('./app/AuthenticatedApp', () => ({
  default: () => <main>家庭画面</main>,
}));

describe('App', () => {
  beforeEach(() => {
    authState.session = null;
    window.localStorage.clear();
    window.history.replaceState({}, '', '/');
  });

  it('renders the Google sign-in screen when no session is present', async () => {
    render(<App />);
    await waitFor(() => {
      expect(screen.getByRole('heading', { name: 'Family Ops' })).toBeInTheDocument();
    });
    expect(screen.getByRole('button', { name: 'Google でサインイン' })).toBeInTheDocument();
  });

  it('opens the household app at / when a Supabase session is stored', async () => {
    authState.session = { user: { id: 'member-1' } };
    window.localStorage.setItem('sb-dnlqxjpjpkxnfgculzip-auth-token', 'stored-session');

    render(<App />);

    expect(await screen.findByText('家庭画面')).toBeInTheDocument();
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });

  it('handles /auth/callback inside the AuthProvider', async () => {
    window.history.replaceState({}, '', '/auth/callback');

    render(<App />);

    expect(
      await screen.findByText('サインインに失敗しました。もう一度お試しください。'),
    ).toBeInTheDocument();
    expect(screen.queryByText('useAuth must be used within an AuthProvider')).not.toBeInTheDocument();
  });
});

import { act, render, screen, waitFor } from '@testing-library/react';
import type { AuthChangeEvent, Session } from '@supabase/supabase-js';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { AuthProvider, useAuth } from './AuthContext';

const auth = vi.hoisted(() => ({ getSession: vi.fn(), onAuthStateChange: vi.fn() }));
vi.mock('../lib/supabaseClient', () => ({ supabase: { auth } }));

function AuthState() {
  const { user, loading, loadError } = useAuth();
  return (
    <output>
      {loading ? 'loading' : loadError ? `error: ${loadError}` : (user?.id ?? 'signed out')}
    </output>
  );
}

function session(userId: string): Session {
  return { user: { id: userId } } as Session;
}

describe('AuthProvider bootstrap ordering', () => {
  let emit: (event: AuthChangeEvent, session: Session | null) => void;
  beforeEach(() => {
    vi.clearAllMocks();
    auth.onAuthStateChange.mockImplementation((listener) => {
      emit = listener;
      return { data: { subscription: { unsubscribe: vi.fn() } } };
    });
  });

  it('does not restore an old session when sign-out arrives before the bootstrap read', async () => {
    let resolve!: (value: { data: { session: Session | null }; error: null }) => void;
    auth.getSession.mockReturnValue(
      new Promise((done) => {
        resolve = done;
      }),
    );
    render(
      <AuthProvider>
        <AuthState />
      </AuthProvider>,
    );
    act(() => emit('SIGNED_OUT', null));
    expect(screen.getByRole('status')).toHaveTextContent('signed out');
    await act(async () => resolve({ data: { session: session('old-user') }, error: null }));
    expect(screen.getByRole('status')).toHaveTextContent('signed out');
  });

  it('does not replace a new login with a stale empty bootstrap result', async () => {
    let resolve!: (value: { data: { session: Session | null }; error: null }) => void;
    auth.getSession.mockReturnValue(
      new Promise((done) => {
        resolve = done;
      }),
    );
    render(
      <AuthProvider>
        <AuthState />
      </AuthProvider>,
    );
    act(() => emit('SIGNED_IN', session('new-user')));
    await act(async () => resolve({ data: { session: null }, error: null }));
    expect(screen.getByRole('status')).toHaveTextContent('new-user');
  });

  it('ignores a late bootstrap rejection after a healthy auth event', async () => {
    let reject!: (reason: Error) => void;
    auth.getSession.mockReturnValue(
      new Promise((_done, fail) => {
        reject = fail;
      }),
    );
    render(
      <AuthProvider>
        <AuthState />
      </AuthProvider>,
    );
    act(() => emit('TOKEN_REFRESHED', session('current-user')));
    await act(async () => reject(new Error('stale request failed')));
    expect(screen.getByRole('status')).toHaveTextContent('current-user');
  });

  it('still surfaces a bootstrap failure when no auth event has resolved the session', async () => {
    auth.getSession.mockRejectedValue(new Error('cannot load session'));
    render(
      <AuthProvider>
        <AuthState />
      </AuthProvider>,
    );
    await waitFor(() =>
      expect(screen.getByRole('status')).toHaveTextContent('error: cannot load session'),
    );
  });
});

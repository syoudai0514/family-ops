import { render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import App from './App';

vi.mock('./lib/supabaseClient', () => ({
  supabase: {
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
      signInWithOAuth: vi.fn(() => Promise.resolve({ error: null })),
    },
  },
}));

describe('App', () => {
  it('renders the Google sign-in screen when no session is present', async () => {
    render(<App />);
    await waitFor(() => {
      expect(screen.getByRole('heading', { name: 'Family Ops' })).toBeInTheDocument();
    });
    expect(screen.getByRole('button', { name: 'Google でサインイン' })).toBeInTheDocument();
  });
});

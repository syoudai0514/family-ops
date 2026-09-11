import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { SignIn } from './SignIn';

const signInWithPassword = vi.hoisted(() => vi.fn());
const signUp = vi.hoisted(() => vi.fn());

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    auth: {
      signInWithPassword,
      signUp,
    },
  },
}));

describe('SignIn email/password auth', () => {
  beforeEach(() => {
    signInWithPassword.mockReset();
    signUp.mockReset();
    window.sessionStorage.clear();
    window.history.replaceState({}, '', '/join?token=invite-token');
  });

  it('signs in with email and password and preserves the invite return path', async () => {
    signInWithPassword.mockResolvedValue({ data: { session: { access_token: 'test' } }, error: null });

    render(<SignIn />);
    fireEvent.change(screen.getByLabelText('メールアドレス'), {
      target: { value: 'mama@example.com' },
    });
    fireEvent.change(screen.getByLabelText('パスワード'), {
      target: { value: 'secret12' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'メールでログイン' }));

    await waitFor(() =>
      expect(signInWithPassword).toHaveBeenCalledWith({
        email: 'mama@example.com',
        password: 'secret12',
      }),
    );
    expect(window.sessionStorage.getItem('family-ops.auth-return-to')).toBe('/join?token=invite-token');
  });

  it('creates an email/password account and explains email confirmation when required', async () => {
    signUp.mockResolvedValue({ data: { session: null }, error: null });

    render(<SignIn />);
    fireEvent.change(screen.getByLabelText('メールアドレス'), {
      target: { value: 'mama@example.com' },
    });
    fireEvent.change(screen.getByLabelText('パスワード'), {
      target: { value: 'secret12' },
    });
    fireEvent.click(screen.getByRole('button', { name: '新規登録' }));

    await waitFor(() =>
      expect(signUp).toHaveBeenCalledWith({
        email: 'mama@example.com',
        password: 'secret12',
        options: {
          emailRedirectTo: 'http://localhost:3000/auth/callback',
        },
      }),
    );
    expect(screen.getByRole('status')).toHaveTextContent(
      '確認メールを送信しました。メール内のリンクを開くと登録が完了します。',
    );
  });

  it('keeps Google sign-in available beside email/password auth', () => {
    render(<SignIn />);
    expect(screen.getByRole('button', { name: 'Google でサインイン' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'メールでログイン' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '新規登録' })).toBeInTheDocument();
  });
});

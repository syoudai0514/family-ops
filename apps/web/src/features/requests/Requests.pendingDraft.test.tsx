import { act, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Requests } from './Requests';
import type { PendingAction } from '../../lib/types';

const api = vi.hoisted(() => ({ callEdgeFunction: vi.fn() }));
vi.mock('../../app/AuthContext', () => ({ useAuth: () => ({ user: { id: 'user-1' } }) }));
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ household: { id: 'household-1' }, partner: { user_id: 'user-2' } }),
}));
vi.mock('../../lib/supabaseClient', async () => {
  const { createSupabaseFromMock } = await import('../../test/supabaseMock');
  return { supabase: { from: createSupabaseFromMock({}) } };
});
vi.mock('../../lib/apiClient', () => ({ ...api, FamilyOpsApiError: class extends Error {} }));
vi.mock('../../lib/useCommandAttempt', () => ({ useCommandAttempt: () => vi.fn() }));

describe('request composer from a LINE pending draft', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
  });

  it('waits for the draft before mounting the composer so its content is preserved', async () => {
    let resolve!: (value: PendingAction[]) => void;
    api.callEdgeFunction.mockReturnValue(
      new Promise((done) => {
        resolve = done;
      }),
    );
    render(
      <MemoryRouter initialEntries={['/requests?pending=draft-1']}>
        <Requests />
      </MemoryRouter>,
    );
    expect(await screen.findByText('LINEの下書きを読み込み中…')).toBeInTheDocument();
    expect(screen.queryByLabelText('タイトル')).not.toBeInTheDocument();
    await act(async () =>
      resolve([
        {
          id: 'draft-1',
          action_type: 'assignment_change_request',
          status: 'draft',
          source: 'line',
          expires_at: '2026-10-12T09:00:00Z',
          created_at: '2026-10-11T08:00:00Z',
          normalized_payload: {
            raw_text: '今日のお迎えお願い',
            title: '今日のお迎え',
            shared_message: '今日18時にお迎えをお願いできますか？',
            due_at: '2026-10-11T09:00:00Z',
          },
        },
      ]),
    );
    expect(screen.getByLabelText('タイトル')).toHaveValue('今日のお迎え');
    expect(screen.getByLabelText('まずはそのまま入力')).toHaveValue('今日のお迎えお願い');
    expect(screen.getByLabelText('相手へ送る文面（確認・編集できます）')).toHaveValue(
      '今日18時にお迎えをお願いできますか？',
    );
    expect(screen.getByLabelText('作業期限（任意）')).toHaveValue('2026-10-11T18:00');
    expect(screen.queryByText('LINEの下書きを読み込み中…')).not.toBeInTheDocument();
  });

  it('does not offer a blank replacement request when the pending draft cannot be found', async () => {
    api.callEdgeFunction.mockResolvedValue([]);
    render(
      <MemoryRouter initialEntries={['/requests?pending=missing']}>
        <Requests />
      </MemoryRouter>,
    );
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'この下書きは見つからないか、すでに処理済みです。',
    );
    expect(screen.queryByLabelText('タイトル')).not.toBeInTheDocument();
    expect(screen.queryByText('送信内容を確認')).not.toBeInTheDocument();
  });
});

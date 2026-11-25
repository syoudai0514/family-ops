import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Requests } from './Requests';
import { FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import type { PendingAction } from '../../lib/types';

const api = vi.hoisted(() => ({ callEdgeFunction: vi.fn(), user: { id: 'user-1' }, household: { id: 'household-1' } }));
vi.mock('../../app/AuthContext', () => ({ useAuth: () => ({ user: api.user }) }));
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ household: api.household, partner: { user_id: 'user-2', profile: { display_name: 'はる' } } }),
}));
vi.mock('../../lib/supabaseClient', async () => {
  const { createSupabaseFromMock } = await import('../../test/supabaseMock');
  return { supabase: { from: createSupabaseFromMock({}) } };
});
vi.mock('../../lib/apiClient', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../lib/apiClient')>()),
  callEdgeFunction: api.callEdgeFunction,
}));

describe('request composer from a LINE pending draft', () => {
  beforeEach(() => {
    api.callEdgeFunction.mockReset();
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
    expect(screen.getByText('今日のお迎えお願い')).not.toBeVisible();
    expect(screen.getAllByRole('textbox')).toHaveLength(2);
    expect(screen.getByLabelText('相手へ送る文面')).toHaveValue(
      '今日18時にお迎えをお願いできますか？',
    );
    expect(screen.getByLabelText('作業期限（任意・日本時間）')).toHaveValue('2026-10-11T18:00');
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

describe('request composer confirmation', () => {
  function openDirectComposer() {
    return render(<MemoryRouter initialEntries={['/requests']}><Requests /></MemoryRouter>);
  }

  async function startDirectComposer() {
    fireEvent.click(await screen.findByRole('button', { name: '+ お願いを送る' }));
    return screen.getByLabelText('相手へ送る文面');
  }

  beforeEach(() => {
    api.callEdgeFunction.mockReset();
    vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
  });

  it('uses the one message for preview and sending without AI, with both deadlines in Tokyo time', async () => {
    api.callEdgeFunction.mockResolvedValue({ request_id: 'request-1' });
    openDirectComposer();
    const message = await startDirectComposer();
    fireEvent.change(message, { target: { value: '  今日のお迎えをお願いできますか？  ' } });
    fireEvent.change(screen.getByLabelText('タイトル'), { target: { value: ' お迎え ' } });
    fireEvent.change(screen.getByLabelText('返事がほしい期限（任意・日本時間）'), { target: { value: '2026-10-11T13:00' } });
    fireEvent.change(screen.getByLabelText('作業期限（任意・日本時間）'), { target: { value: '2026-10-11T18:00' } });
    fireEvent.click(screen.getByRole('button', { name: '送信内容を確認' }));
    expect(screen.getByRole('region', { name: '送信内容の確認' })).toHaveTextContent('宛先 はるさん');
    expect(screen.getByRole('heading', { name: 'お迎え' })).toBeInTheDocument();
    expect(screen.getByText(/作業期限.*18:00（日本時間）/)).toBeInTheDocument();
    expect(screen.getByText('今日のお迎えをお願いできますか？')).toBeInTheDocument();
    expect(api.callEdgeFunction).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: 'この内容でお願いを送る' }));
    expect(await screen.findByRole('status')).toHaveTextContent('はるさんへのお願いを送りました。');
    expect(api.callEdgeFunction).toHaveBeenCalledExactlyOnceWith(EDGE_FUNCTIONS.sendRequest, {
      operation_id: expect.any(String),
      recipient_user_id: 'user-2',
      shared_title: 'お迎え',
      shared_message: '今日のお迎えをお願いできますか？',
      due_at: '2026-10-11T09:00:00.000Z',
      reply_due_at: '2026-10-11T04:00:00.000Z',
    });
  });

  it('keeps a LINE draft original private until rewrite is requested, then sends only the final edited text', async () => {
    api.callEdgeFunction
      .mockResolvedValueOnce([{
        id: 'draft-2',
        action_type: 'assignment_change_request',
        status: 'draft',
        source: 'line',
        normalized_payload: { raw_text: '個人的な事情' },
      }])
      .mockResolvedValueOnce({ raw_input_id: 'private-id', proposed_text: '夕食をお願いできますか？' })
      .mockResolvedValueOnce({ request_id: 'request-2' })
      .mockResolvedValueOnce({});
    render(<MemoryRouter initialEntries={['/requests?pending=draft-2']}><Requests /></MemoryRouter>);

    const message = await screen.findByLabelText('相手へ送る文面');
    expect(message).toHaveValue('');
    expect(screen.getByRole('button', { name: '送信内容を確認' })).toBeDisabled();
    expect(screen.getByText('個人的な事情')).not.toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: '下書きの原文からAIで文面を作る' }));
    await waitFor(() => expect(message).toHaveValue('夕食をお願いできますか？'));
    expect(api.callEdgeFunction).toHaveBeenNthCalledWith(2, EDGE_FUNCTIONS.proposeAiDraft, {
      operation_id: expect.any(String), raw_text: '個人的な事情', target_type: 'request',
    });
    fireEvent.change(message, { target: { value: '夕食の準備をお願いできますか？' } });
    fireEvent.click(screen.getByRole('button', { name: '送信内容を確認' }));
    expect(screen.queryByText('個人的な事情')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'この内容でお願いを送る' }));
    expect(await screen.findByRole('status')).toHaveTextContent('はるさんへのお願いを送りました。');
    expect(api.callEdgeFunction).toHaveBeenNthCalledWith(3, EDGE_FUNCTIONS.confirmRequestDraft, {
      operation_id: expect.any(String),
      recipient_user_id: 'user-2',
      shared_title: 'お願い',
      confirmed_message: '夕食の準備をお願いできますか？',
      raw_input_id: 'private-id',
    });
    expect(api.callEdgeFunction).toHaveBeenNthCalledWith(4, EDGE_FUNCTIONS.cancelPendingAction, { pending_action_id: 'draft-2' });
  });

  it('restores an unknown send and reuses its operation and exact confirmed payload', async () => {
    api.callEdgeFunction
      .mockRejectedValueOnce(new FamilyOpsApiError('NETWORK_ERROR', 'lost response', 0, undefined, 'unknown'))
      .mockRejectedValueOnce(new FamilyOpsApiError('AUTH_TIMEOUT', 'retry did not reach the server', 0, undefined, 'not_sent'))
      .mockResolvedValueOnce({ request_id: 'request-3' });
    const firstVisit = openDirectComposer();
    const message = await startDirectComposer();
    fireEvent.change(message, { target: { value: '明日のお迎えをお願いできますか？' } });
    fireEvent.click(screen.getByRole('button', { name: '送信内容を確認' }));
    fireEvent.click(screen.getByRole('button', { name: 'この内容でお願いを送る' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('送信結果を確認できませんでした');
    expect(screen.queryByRole('button', { name: '編集に戻る' })).not.toBeInTheDocument();
    firstVisit.unmount();

    openDirectComposer();
    fireEvent.click(await screen.findByRole('button', { name: '+ お願いを送る' }));
    expect(await screen.findByText('明日のお迎えをお願いできますか？')).toBeInTheDocument();
    expect(screen.queryByLabelText('相手へ送る文面')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '送信結果を確認' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('送信結果を確認できませんでした');
    expect(screen.queryByRole('button', { name: '編集に戻る' })).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '送信結果を確認' }));
    expect(await screen.findByText(/はるさんへのお願いを送りました。/)).toHaveAttribute('role', 'status');
    expect(api.callEdgeFunction.mock.calls).toEqual(Array(3).fill(api.callEdgeFunction.mock.calls[0]));
  });
});

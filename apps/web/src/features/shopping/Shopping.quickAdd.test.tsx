import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Shopping } from './Shopping';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';

const runCommand = vi.fn();
const rpc = vi.fn();

vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ household: { id: 'household-1' }, members: [], me: { user_id: 'user-1' } }),
}));
vi.mock('../../lib/useCommandAttempt', () => ({ useCommandAttempt: () => runCommand }));
vi.mock('../../lib/useRealtimeRefresh', () => ({ useRealtimeRefresh: () => undefined }));
vi.mock('../../lib/supabaseClient', () => ({ supabase: { rpc: (...args: unknown[]) => rpc(...args) } }));

const milk = { shopping_item_id: 'item-1', title: '牛乳', status: 'wanted', purchase_method: 'undecided', revision: 1 };

describe('Shopping quick add', () => {
  beforeEach(() => {
    runCommand.mockReset();
    runCommand.mockResolvedValue({ shopping_item_id: 'new' });
    rpc.mockReset();
    rpc.mockResolvedValue({ data: { actor_ref_id: 'actor-1', active: [milk], history: [] }, error: null });
  });

  it('adds several items from one line and skips ones already on the list', async () => {
    render(<MemoryRouter><Shopping /></MemoryRouter>);
    const input = await screen.findByLabelText('買うものを追加');
    fireEvent.change(input, { target: { value: '卵、牛乳、パン' } });
    fireEvent.click(screen.getByRole('button', { name: '追加' }));

    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('2件追加しました。牛乳はもうリストにあります。'));
    expect(runCommand.mock.calls.map((call) => call[2]('op').title)).toEqual(['卵', 'パン']);
    expect(runCommand.mock.calls[0][1]).toBe(EDGE_FUNCTIONS.addShoppingItem);
    expect(input).toHaveValue('');
  });

  it('keeps the list on screen while refreshing after an action', async () => {
    let finishRefresh: (value: unknown) => void = () => undefined;
    render(<MemoryRouter><Shopping /></MemoryRouter>);
    const purchase = await screen.findByRole('button', { name: '購入した' });
    rpc.mockReturnValueOnce(new Promise((resolve) => { finishRefresh = resolve; }));
    fireEvent.click(purchase);
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(2));
    expect(screen.queryByText('読み込み中…')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: '購入した' })).toBeInTheDocument();
    finishRefresh({ data: { actor_ref_id: 'actor-1', active: [], history: [] }, error: null });
    expect(await screen.findByText('いま買うものはありません。')).toBeInTheDocument();
  });
});

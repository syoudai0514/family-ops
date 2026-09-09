import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { AnyoneOwnerPage } from './AnyoneOwnerPage';
import * as apiClient from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { supabase } from '../../lib/supabaseClient';

vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ household: { id: 'household-1' } }),
}));

vi.mock('../../lib/supabaseClient', () => ({
  supabase: { rpc: vi.fn() },
}));

vi.mock('../../lib/apiClient', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../lib/apiClient')>();
  return { ...actual, callEdgeFunction: vi.fn() };
});

const rpc = vi.mocked(supabase.rpc);
const callEdgeFunction = vi.mocked(apiClient.callEdgeFunction);
const baseItem = {
  shopping_item_id: 'item-1',
  title: '牛乳',
  assignment_mode: 'anyone',
  revision: 3,
};

function workspace(activeClaimantActorRefId: string | null, revision = 3, displayName?: string | null) {
  return {
    data: {
      actor_ref_id: 'me',
      active: [{
        ...baseItem,
        revision,
        active_claimant_actor_ref_id: activeClaimantActorRefId,
        active_claimant_display_name: displayName ?? null,
      }],
    },
    error: null,
    success: true as const,
    count: null,
    status: 200,
    statusText: 'OK',
  };
}

function renderPage() {
  return render(
    <MemoryRouter>
      <AnyoneOwnerPage />
    </MemoryRouter>,
  );
}

describe('Q107-Q109 anyone-owner state-transition interaction evidence', () => {
  beforeEach(() => {
    rpc.mockReset();
    callEdgeFunction.mockReset();
    callEdgeFunction.mockResolvedValue({ ok: true });
  });

  it('Q107/Q108 claims an unclaimed anyone item and reloads the canonical claimant state', async () => {
    rpc.mockResolvedValueOnce(workspace(null)).mockResolvedValueOnce(workspace('me', 4));
    renderPage();

    expect(await screen.findByText('牛乳')).toBeInTheDocument();
    expect(screen.getByText(/現在: まだ誰も対応中ではありません/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '自分がやる' }));

    await waitFor(() => {
      expect(callEdgeFunction).toHaveBeenCalledWith(EDGE_FUNCTIONS.claimShoppingItem, {
        operation_id: expect.any(String),
        shopping_item_id: 'item-1',
        action: 'claim',
        expected_revision: 3,
      });
    });
    expect(await screen.findByText(/現在: 自分が対応中/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '手放す' })).toBeInTheDocument();
  });

  it('Q108 identifies the current claimant and sends takeover only after explicit action', async () => {
    rpc.mockResolvedValueOnce(workspace('partner', 3, 'ママ')).mockResolvedValueOnce(workspace('me', 4));
    renderPage();

    expect(await screen.findByText(/現在: ママが対応中/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '引き継ぐ' }));

    await waitFor(() => {
      expect(callEdgeFunction).toHaveBeenCalledWith(EDGE_FUNCTIONS.claimShoppingItem, {
        operation_id: expect.any(String),
        shopping_item_id: 'item-1',
        action: 'takeover',
        expected_revision: 3,
      });
    });
    expect(await screen.findByText(/現在: 自分が対応中/)).toBeInTheDocument();
  });

  it('Q109 does not release on render; release requires the exact explicit 手放す action', async () => {
    rpc.mockResolvedValueOnce(workspace('me')).mockResolvedValueOnce(workspace(null, 4));
    renderPage();

    expect(await screen.findByText(/現在: 自分が対応中/)).toBeInTheDocument();
    expect(callEdgeFunction).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: '手放す' }));

    await waitFor(() => {
      expect(callEdgeFunction).toHaveBeenCalledWith(EDGE_FUNCTIONS.claimShoppingItem, {
        operation_id: expect.any(String),
        shopping_item_id: 'item-1',
        action: 'release',
        expected_revision: 3,
      });
    });
    expect(await screen.findByText(/現在: まだ誰も対応中ではありません/)).toBeInTheDocument();
  });

  it('fails closed when a non-self claimant cannot be identified', async () => {
    rpc.mockResolvedValueOnce(workspace('partner'));
    renderPage();

    expect(await screen.findByText(/現在: 対応者を確認できません/)).toBeInTheDocument();
    expect(screen.queryByText(/家族が対応中/)).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: '引き継ぐ' })).toBeInTheDocument();
  });
});

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

function workspace(activeClaimantActorRefId: string | null, revision = 3) {
  return {
    data: {
      actor_ref_id: 'me',
      active: [{ ...baseItem, revision, active_claimant_actor_ref_id: activeClaimantActorRefId }],
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

describe('Q107-Q109 anyone-owner actual interaction evidence', () => {
  beforeEach(() => {
    rpc.mockReset();
    callEdgeFunction.mockReset();
    callEdgeFunction.mockResolvedValue({ ok: true });
  });

  it('Q107/Q108 renders an unclaimed anyone item, claims it by click, then reloads the canonical claimant state', async () => {
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
    expect(screen.getByRole('button', { name: '担当を戻す' })).toBeInTheDocument();
  });

  it('Q108 exposes takeover only when another family member is the current claimant and converges after the click', async () => {
    rpc.mockResolvedValueOnce(workspace('partner')).mockResolvedValueOnce(workspace('me', 4));
    renderPage();

    expect(await screen.findByText(/現在: 家族が対応中/)).toBeInTheDocument();
    expect(screen.getByText(/「引き継ぐ」を押すと現在の担当を自分へ変更/)).toBeInTheDocument();

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

  it('Q109 does not release on render; release requires the claimant to press the explicit action', async () => {
    rpc.mockResolvedValueOnce(workspace('me')).mockResolvedValueOnce(workspace(null, 4));
    renderPage();

    expect(await screen.findByText(/現在: 自分が対応中/)).toBeInTheDocument();
    expect(callEdgeFunction).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: '担当を戻す' }));

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
});

import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { HouseholdSetup } from './HouseholdSetup';

const callEdgeFunction = vi.hoisted(() => vi.fn());
const refresh = vi.hoisted(() => vi.fn());

vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ refresh }),
}));
vi.mock('../../lib/apiClient', () => ({
  callEdgeFunction,
  FamilyOpsApiError: class extends Error {},
}));
vi.mock('../../lib/edgeFunctions', () => ({
  EDGE_FUNCTIONS: {
    createHousehold: 'create-household',
    joinHousehold: 'join-household',
  },
}));
vi.mock('../../lib/id', () => ({ newOperationId: () => 'operation-id' }));

describe('HouseholdSetup invite join contract', () => {
  beforeEach(() => {
    callEdgeFunction.mockReset();
    callEdgeFunction.mockResolvedValue({ household_id: 'household-1' });
    refresh.mockReset();
    window.history.replaceState({}, '', '/join?token=invite-token');
  });

  it('sends the invite token using the Edge Function raw_invite_token field', async () => {
    render(
      <MemoryRouter>
        <HouseholdSetup />
      </MemoryRouter>,
    );

    fireEvent.change(screen.getByLabelText('あなたの表示名'), {
      target: { value: 'はなこ' },
    });
    fireEvent.click(screen.getByRole('button', { name: '参加する' }));

    await waitFor(() =>
      expect(callEdgeFunction).toHaveBeenCalledWith('join-household', {
        operation_id: 'operation-id',
        raw_invite_token: 'invite-token',
        display_name: 'はなこ',
      }),
    );
    expect(callEdgeFunction.mock.calls[0][1]).not.toHaveProperty('invite_token');
  });
});

import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';
import { ConciergeResultsPage } from './ConciergeResultsPage';
import { callEdgeFunction } from '../../lib/apiClient';
vi.mock('../../lib/apiClient', async () => ({
  ...(await vi.importActual('../../lib/apiClient')),
  callEdgeFunction: vi.fn(),
}));
vi.mock('../../app/AuthContext', () => ({ useAuth: () => ({ user: { id: 'confirm-user' } }) }));
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({
    household: { id: 'confirm-family', timezone: 'Asia/Tokyo' },
    members: [],
    me: { user_id: 'confirm-user', household_id: 'confirm-family' },
    partner: null,
  }),
}));
describe('simple addition', () => {
  it('registers from a single review screen and freezes the confirmed selection', async () => {
    vi.mocked(callEdgeFunction).mockResolvedValue({ shopping_item_id: 'milk' });
    render(
      <MemoryRouter
        initialEntries={[
          {
            pathname: '/concierge/results',
            state: {
              candidates: [
                {
                  candidateId: 'milk-candidate',
                  operationId: '00000000-0000-4000-8000-000000000123',
                  candidateRevision: 1,
                  kind: 'shopping',
                  title: '牛乳',
                  sourceText: '牛乳を買いたい',
                  intent: null,
                  missingFields: [],
                  duplicateMatch: null,
                },
              ],
            },
          },
        ]}
      >
        <ConciergeResultsPage />
      </MemoryRouter>,
    );
    expect(screen.getAllByText('牛乳')).toHaveLength(1);
    expect(callEdgeFunction).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: '選んだ内容を登録' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(1));
    expect(screen.getByRole('checkbox')).toBeDisabled();
    expect(await screen.findByText('登録完了')).toBeInTheDocument();
  });
});

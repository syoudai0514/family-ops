import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { FamilyRoles } from './FamilyRoles';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';

const refresh = vi.fn(async () => {});
vi.mock('../../lib/apiClient', async () => ({
  ...(await vi.importActual('../../lib/apiClient')),
  callEdgeFunction: vi.fn(),
}));
vi.mock('../../app/AuthContext', () => ({ useAuth: () => ({ user: { id: 'roles-user' } }) }));
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({
    household: { id: 'roles-family' },
    refresh,
    members: [
      { user_id: 'roles-user', family_role: 'papa', profile: { display_name: '太郎' } },
      { user_id: 'roles-partner', family_role: 'mama', profile: { display_name: '花子' } },
    ],
  }),
}));
describe('family role confirmation', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(callEdgeFunction).mockResolvedValue({ ok: true });
  });
  it('shows both changed labels and saves only after explicit confirmation', async () => {
    render(<FamilyRoles />);
    fireEvent.change(screen.getByLabelText('太郎'), { target: { value: 'mama' } });
    expect(callEdgeFunction).not.toHaveBeenCalled();
    expect(screen.getByText('太郎 → ママ（橙）')).toBeInTheDocument();
    expect(screen.getByText('花子 → パパ（緑）')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'この表示で保存' }));
    await waitFor(() =>
      expect(callEdgeFunction).toHaveBeenCalledWith(
        'set-family-role',
        expect.objectContaining({ user_id: 'roles-user', family_role: 'mama' }),
      ),
    );
    expect(await screen.findByRole('status')).toHaveTextContent('保存しました');
  });
  it('retains a failed selection and retries a response-lost save with the same operation', async () => {
    vi.mocked(callEdgeFunction)
      .mockRejectedValueOnce(
        new FamilyOpsApiError('TIMEOUT', '保存結果を確認できません', 0, undefined, 'unknown'),
      )
      .mockResolvedValueOnce({ ok: true });
    render(<FamilyRoles />);
    fireEvent.change(screen.getByLabelText('花子'), { target: { value: 'papa' } });
    fireEvent.click(screen.getByRole('button', { name: 'この表示で保存' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('保存結果');
    fireEvent.click(screen.getByRole('button', { name: 'この表示で保存' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledTimes(2));
    expect(
      (vi.mocked(callEdgeFunction).mock.calls[1][1] as Record<string, unknown>).operation_id,
    ).toBe((vi.mocked(callEdgeFunction).mock.calls[0][1] as Record<string, unknown>).operation_id);
  });
});

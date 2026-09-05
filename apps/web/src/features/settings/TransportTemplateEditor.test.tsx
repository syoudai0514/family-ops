import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import { callEdgeFunction } from '../../lib/apiClient';
import { TransportTemplateEditor } from './TransportTemplateEditor';

vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return { ...actual, callEdgeFunction: vi.fn() };
});

const api = vi.mocked(callEdgeFunction);
const members = [
  { user_id: 'papa', profile: { display_name: 'パパ' } },
  { user_id: 'mama', profile: { display_name: 'ママ' } },
] as unknown as HouseholdMemberWithProfile[];

const currentTemplate = {
  id: 'template-a',
  valid_from: '2026-09-01',
  valid_to: null,
  revision: 1,
  days: Array.from({ length: 7 }, (_, index) => ({
    weekday: index + 1,
    dropoff_user_id: 'papa',
    pickup_user_id: 'mama',
    dropoff_local_time: '08:00:00',
    pickup_local_time: '17:30:00',
  })),
};

describe('TransportTemplateEditor', () => {
  beforeEach(() => {
    api.mockReset();
    api.mockResolvedValueOnce({ templates: [currentTemplate], overrides: [] });
  });

  it('shows an open-ended period and saves the whole seven-day matrix in one command', async () => {
    render(<TransportTemplateEditor members={members} />);
    expect(await screen.findByText('9/1 ～ 期限未定')).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText('この生活パターンを始める日'), {
      target: { value: '2026-10-01' },
    });
    api.mockResolvedValueOnce({ protected_conflicts: [] });
    api.mockResolvedValueOnce({ templates: [currentTemplate], overrides: [] });
    fireEvent.click(screen.getByRole('button', { name: 'この日から新しい生活パターンとして保存' }));

    await waitFor(() => {
      const saveCall = api.mock.calls.find(([, body]) => body?.action === 'save_template');
      expect(saveCall).toBeTruthy();
      expect(saveCall?.[1]).toMatchObject({ valid_from: '2026-10-01' });
      expect((saveCall?.[1] as { days: unknown[] }).days).toHaveLength(7);
    });
  });

  it('surfaces protected individual agreements instead of silently overwriting them', async () => {
    render(<TransportTemplateEditor members={members} />);
    await screen.findByText('9/1 ～ 期限未定');
    api.mockResolvedValueOnce({
      protected_conflicts: [
        { task_id: 'protected', date: '2026-10-05', leg: 'pickup', planned_assignee_user_id: 'mama', assignment_source: 'agreement' },
      ],
    });
    api.mockResolvedValueOnce({ templates: [currentTemplate], overrides: [] });
    fireEvent.click(screen.getByRole('button', { name: 'この日から新しい生活パターンとして保存' }));
    expect(await screen.findByText(/個別に確定済みの1件は変更せず維持/)).toBeInTheDocument();
  });
});

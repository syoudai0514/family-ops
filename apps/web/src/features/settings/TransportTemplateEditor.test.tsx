import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import { callEdgeFunction } from '../../lib/apiClient';
import { TransportTemplateEditor } from './TransportTemplateEditor';

vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return { ...actual, callEdgeFunction: vi.fn() };
});
vi.mock('../../lib/id', () => ({ newOperationId: () => '00000000-0000-4000-8000-000000000001' }));

const api = vi.mocked(callEdgeFunction);
const members = [
  { user_id: 'papa', profile: { display_name: 'パパ' } },
  { user_id: 'mama', profile: { display_name: 'ママ' } },
] as unknown as HouseholdMemberWithProfile[];
const currentTemplate = {
  id: 'template-a', valid_from: '2026-09-01', valid_to: null, revision: 1,
  days: Array.from({ length: 7 }, (_, index) => ({ weekday: index + 1, dropoff_user_id: 'papa', pickup_user_id: 'mama', dropoff_local_time: '08:00:00', pickup_local_time: '17:30:00' })),
};
const review = {
  id: 'review-1', revision: 1, status: 'pending' as const, my_response: null,
  items: [{ task_id: 'protected', date: '2026-10-05', leg: 'pickup' as const }],
};

function installApi(conflictReviews: typeof review[] = []) {
  api.mockImplementation((_name, body) => {
    const action = (body as Record<string, unknown>)?.action;
    if (action === 'read') return Promise.resolve({ templates: [currentTemplate], overrides: [] });
    if (action === 'list_conflict_reviews') return Promise.resolve(conflictReviews);
    if (action === 'save_template') return Promise.resolve({ protected_conflicts: [] });
    if (action === 'respond_conflict_review') return Promise.resolve({ status: 'pending' });
    return Promise.resolve({});
  });
}

describe('TransportTemplateEditor Q50', () => {
  beforeEach(() => { api.mockReset(); installApi(); });

  it('shows an open-ended period and saves the whole seven-day matrix in one command', async () => {
    render(<TransportTemplateEditor members={members} />);
    expect(await screen.findByText('9/1 ～ 期限未定')).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('この生活パターンを始める日'), { target: { value: '2026-10-01' } });
    fireEvent.click(screen.getByRole('button', { name: 'この日から新しい生活パターンとして保存' }));
    await waitFor(() => {
      const saveCall = api.mock.calls.find(([, body]) => (body as Record<string, unknown>).action === 'save_template');
      expect(saveCall).toBeDefined();
      const saveBody = saveCall?.[1] as { valid_from: string; days: unknown[] };
      expect(saveBody.valid_from).toBe('2026-10-01');
      expect(saveBody.days).toHaveLength(7);
    });
  });

  it('keeps protected individual agreements and tells both users confirmation is required', async () => {
    installApi();
    api.mockImplementation((_name, body) => {
      const action = (body as Record<string, unknown>)?.action;
      if (action === 'read') return Promise.resolve({ templates: [currentTemplate], overrides: [] });
      if (action === 'list_conflict_reviews') return Promise.resolve([]);
      if (action === 'save_template') return Promise.resolve({ protected_conflicts: [{ task_id: 'protected', date: '2026-10-05', leg: 'pickup', planned_assignee_user_id: 'mama', assignment_source: 'agreement' }] });
      return Promise.resolve({});
    });
    render(<TransportTemplateEditor members={members} />);
    await screen.findByText('9/1 ～ 期限未定');
    fireEvent.click(screen.getByRole('button', { name: 'この日から新しい生活パターンとして保存' }));
    expect(await screen.findByText(/個別合意1件は変更せず、パパ・ママ双方の維持確認を待っています/)).toBeInTheDocument();
    expect(screen.getByText('2026-10-05 · お迎え')).toBeInTheDocument();
  });

  it('renders durable bilateral keep/review choices and submits revision-CAS response', async () => {
    installApi([review]);
    render(<TransportTemplateEditor members={members} />);
    expect(await screen.findByText('個別に合意済みの予定を維持しますか？')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '維持する' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '見直す' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '見直す' }));
    await waitFor(() => expect(api).toHaveBeenCalledWith(expect.any(String), expect.objectContaining({
      action: 'respond_conflict_review', review_id: 'review-1', expected_revision: 1, response: 'review',
    })));
  });
});

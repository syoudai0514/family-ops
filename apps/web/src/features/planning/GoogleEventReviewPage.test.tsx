import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { GoogleEventReviewPage } from './GoogleEventReviewPage';

const callEdgeFunction = vi.fn();
vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return { ...actual, callEdgeFunction: (...args: unknown[]) => callEdgeFunction(...args) };
});
vi.mock('../../lib/id', () => ({ newOperationId: () => '00000000-0000-4000-8000-000000000001' }));

const BASE = {
  revision: 4,
  family_event_title: '保育園面談',
  family_event_all_day: false,
  family_event_starts_at: '2026-10-10T01:00:00Z',
  family_event_ends_at: '2026-10-10T01:30:00Z',
  family_event_starts_on: null,
  family_event_ends_on: null,
  family_event_location_text: '保育園',
  google_title: '保育園面談',
  google_all_day: false,
  google_starts_at: '2026-10-10T02:00:00Z',
  google_ends_at: '2026-10-10T02:30:00Z',
  google_starts_on: null,
  google_ends_on: null,
  google_location_text: '保育園',
  changed_fields: ['schedule'],
};

function renderPage() { return render(<MemoryRouter><GoogleEventReviewPage /></MemoryRouter>); }
function mockSingle(candidate: Record<string, unknown>) {
  callEdgeFunction.mockImplementation((name: string) => name === 'list-google-event-reviews'
    ? Promise.resolve([candidate]) : Promise.resolve({ status: 'resolved' }));
}

describe('GoogleEventReviewPage Q110-Q112', () => {
  beforeEach(() => callEdgeFunction.mockReset());

  it('shows protected Family Ops vs Google values and requires explicit accept/keep', async () => {
    mockSingle({ ...BASE, id: 'review-change', candidate_kind: 'protected_change' });
    renderPage();
    expect(await screen.findByText('人が確認した内容は自動で上書きしていません。差分を確認してください。')).toBeInTheDocument();
    expect(screen.getByText(/おうちノート: 10\/10 10:00/)).toBeInTheDocument();
    expect(screen.getByText(/Google: 10\/10 11:00/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Googleの変更を反映' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('resolve-google-event-review', expect.objectContaining({
      candidateId: 'review-change', candidateKind: 'protected_change', expectedRevision: 4, resolution: 'accept_google',
    })));
  });

  it('Q111 exposes the literal three Google-deletion choices', async () => {
    mockSingle({ ...BASE, id: 'review-delete', candidate_kind: 'google_deleted', changed_fields: ['status'] });
    renderPage();
    expect(await screen.findByText('Googleでは削除されています。おうちノート側はまだ削除していません。')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '予定を中止' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '日程変更待ち' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Googleのみ非表示' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '日程変更待ち' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('resolve-google-event-review', expect.objectContaining({
      candidateId: 'review-delete', candidateKind: 'google_deleted', resolution: 'waiting_reschedule',
    })));
  });

  it('Q110 shows a linked incomplete preparation as a reviewable change rather than auto-shifting it', async () => {
    mockSingle({ id: 'prep-1', revision: 1, candidate_kind: 'preparation_change', proposal_kind: 'reschedule',
      family_event_title: '遠足', task_title: '水筒を準備', old_scheduled_date: '2026-10-07', proposed_scheduled_date: '2026-10-09',
      old_due_at: '2026-10-07T11:00:00Z', proposed_due_at: '2026-10-09T11:00:00Z' });
    renderPage();
    expect(await screen.findByText('関連する準備の変更候補')).toBeInTheDocument();
    expect(screen.getByText('水筒を準備')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '変更を反映' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('resolve-google-event-review', expect.objectContaining({
      candidateId: 'prep-1', candidateKind: 'preparation_change', resolution: 'apply',
    })));
  });

  it('Q111 cancellation keeps linked prep as an explicit unnecessary candidate', async () => {
    mockSingle({ id: 'prep-cancel', revision: 2, candidate_kind: 'preparation_change', proposal_kind: 'unnecessary',
      family_event_title: '遠足', task_title: '水筒を準備' });
    renderPage();
    expect(await screen.findByText('関連する準備の不要候補')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '今回は不要にする' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'このまま' })).toBeInTheDocument();
  });

  it('offers exactly same-event vs different-event for a duplicate candidate', async () => {
    mockSingle({ ...BASE, id: 'review-dup', candidate_kind: 'possible_duplicate', family_event_title: '運動会', google_title: '運動会' });
    renderPage();
    expect(await screen.findByText('Googleにも同じ日時・同じ名前の予定があります。')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '同じ予定' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('resolve-google-event-review', expect.objectContaining({
      candidateId: 'review-dup', candidateKind: 'possible_duplicate', resolution: 'same_event',
    })));
    expect(screen.getByRole('button', { name: '別の予定' })).toBeInTheDocument();
  });
});

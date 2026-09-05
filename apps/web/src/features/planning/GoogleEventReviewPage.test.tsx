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

function renderPage() {
  return render(<MemoryRouter><GoogleEventReviewPage /></MemoryRouter>);
}

describe('GoogleEventReviewPage Q110-Q112', () => {
  beforeEach(() => {
    callEdgeFunction.mockReset();
  });

  it('shows protected Family Ops vs Google values and requires explicit accept/keep', async () => {
    callEdgeFunction.mockImplementation((name: string) => name === 'list-google-event-reviews'
      ? Promise.resolve([{ ...BASE, id: 'review-change', candidate_kind: 'protected_change' }])
      : Promise.resolve({ status: 'resolved' }));
    renderPage();
    expect(await screen.findByText('人が確認した内容は自動で上書きしていません。差分を確認してください。')).toBeInTheDocument();
    expect(screen.getByText(/おうちノート: 10\/10 10:00/)).toBeInTheDocument();
    expect(screen.getByText(/Google: 10\/10 11:00/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Googleの変更を反映' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('resolve-google-event-review', expect.objectContaining({
      candidateId: 'review-change', expectedRevision: 4, resolution: 'accept_google',
    })));
  });

  it('does not silently delete a Google-removed event', async () => {
    callEdgeFunction.mockImplementation((name: string) => name === 'list-google-event-reviews'
      ? Promise.resolve([{ ...BASE, id: 'review-delete', candidate_kind: 'google_deleted', changed_fields: ['status'] }])
      : Promise.resolve({ status: 'resolved' }));
    renderPage();
    expect(await screen.findByText('Googleでは削除されています。おうちノート側はまだ削除していません。')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '予定を残す' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '削除を反映' })).toBeInTheDocument();
  });

  it('offers exactly same-event vs different-event for a duplicate candidate', async () => {
    callEdgeFunction.mockImplementation((name: string) => name === 'list-google-event-reviews'
      ? Promise.resolve([{ ...BASE, id: 'review-dup', candidate_kind: 'possible_duplicate', family_event_title: '運動会', google_title: '運動会' }])
      : Promise.resolve({ status: 'resolved' }));
    renderPage();
    expect(await screen.findByText('Googleにも同じ日時・同じ名前の予定があります。')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '同じ予定' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('resolve-google-event-review', expect.objectContaining({
      candidateId: 'review-dup', resolution: 'same_event',
    })));
    expect(screen.getByRole('button', { name: '別の予定' })).toBeInTheDocument();
  });
});

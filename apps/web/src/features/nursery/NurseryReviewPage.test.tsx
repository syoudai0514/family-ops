import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { NurseryReviewPage } from './NurseryReviewPage';

const callEdgeFunction = vi.fn();
vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return { ...actual, callEdgeFunction: (...args: unknown[]) => callEdgeFunction(...args) };
});
vi.mock('../../lib/id', () => ({ newOperationId: () => '00000000-0000-4000-8000-000000000001' }));

const REVIEW = {
  intake_id: 'intake-1',
  status: 'review_ready',
  revision: 7,
  child_school_context_id: 'ctx-1',
  context_confidence: 'high',
  ambiguity_fields: [],
  source_document_id: 'doc-1',
  raw_available: true,
  source_image_url: 'https://signed.example/source.jpg',
  available_contexts: [{ id: 'ctx-1', school_display_name: 'ひかり園', class_display_name: 'そら組', child_display_name: 'こども' }],
  items: [
    {
      id: 'item-explicit', candidate_key: 'event', origin: 'source_explicit', item_kind: 'task', classification: null,
      source_document_id: 'doc-1', source_page: 1, source_locator: '上段', proposed_value: { title: '遠足の準備', due_date: '2026-09-10' }, confidence_band: 'high', previous_confirmed_item_id: null,
    },
    {
      id: 'item-ai', candidate_key: 'ai-prep', origin: 'ai_inference', item_kind: 'preparation', classification: null,
      source_document_id: 'doc-1', source_page: 1, source_locator: null, proposed_value: { preparation_template: { item: '水筒' } }, confidence_band: 'medium', previous_confirmed_item_id: 'old-1',
    },
    {
      id: 'item-other', candidate_key: 'other', origin: 'source_explicit', item_kind: 'timetable', classification: 'other',
      source_document_id: 'doc-1', source_page: 2, source_locator: '下段', proposed_value: { title: '園内会議', due_date: '2026-09-11' }, confidence_band: 'high', previous_confirmed_item_id: null,
    },
  ],
};

function renderReview() {
  return render(
    <MemoryRouter initialEntries={['/nursery/reviews/intake-1']}>
      <Routes><Route path="/nursery/reviews/:intakeId" element={<NurseryReviewPage />} /></Routes>
    </MemoryRouter>,
  );
}

describe('NurseryReviewPage', () => {
  beforeEach(() => {
    callEdgeFunction.mockReset();
    callEdgeFunction.mockImplementation((name: string) => {
      if (name === 'get-nursery-review') return Promise.resolve(REVIEW);
      if (name === 'confirm-nursery-review') return Promise.resolve({ confirmed: true, intake_id: 'intake-1' });
      return Promise.resolve({});
    });
  });

  it('shows source provenance, AI inference, source page, diff, raw image and retains Other for review', async () => {
    renderReview();
    expect(await screen.findByRole('heading', { name: 'この内容で登録しますか？' })).toBeInTheDocument();
    expect(screen.getByAltText('確認中のおたより原画像')).toHaveAttribute('src', 'https://signed.example/source.jpg');
    expect(screen.getAllByText(/おたよりに明記/).length).toBeGreaterThan(0);
    expect(screen.getByText(/AIの推測/)).toBeInTheDocument();
    expect(screen.getByText('出典: 画像 1ページ目 · 上段')).toBeInTheDocument();
    expect(screen.getByText(/前回確定した内容があります/)).toBeInTheDocument();
    expect(screen.getByText('その他の予定 — 消さずに確認できます')).toBeInTheDocument();
  });

  it('shows a reviewed family-share candidate with editable share text and date', async () => {
    callEdgeFunction.mockImplementation((name: string) => {
      if (name === 'get-nursery-review') return Promise.resolve({
        ...REVIEW,
        items: [
          ...REVIEW.items,
          {
            id: 'item-share', candidate_key: 'share', origin: 'source_explicit', item_kind: 'shared_info', classification: null,
            source_document_id: 'doc-1', source_page: 2, source_locator: '注意事項',
            proposed_value: { text: '当日は園指定の体操服で登園', date: '2026-10-08' }, confidence_band: 'high', previous_confirmed_item_id: null,
          },
        ],
      });
      return Promise.resolve({});
    });
    renderReview();
    expect(await screen.findByRole('heading', { name: '家族への共有' })).toBeInTheDocument();
    expect(screen.getByLabelText('共有内容')).toHaveValue('当日は園指定の体操服で登園');
    expect(screen.getByLabelText('日付')).toHaveAttribute('type', 'date');
    expect(screen.getByText('出典: 画像 2ページ目 · 注意事項')).toBeInTheDocument();
  });

  it('sends only selected candidates and carries the human-edited field to confirm', async () => {
    renderReview();
    await screen.findByRole('heading', { name: 'この内容で登録しますか？' });
    const contentInputs = screen.getAllByLabelText('内容');
    fireEvent.change(contentInputs[0], { target: { value: '遠足の持ち物を準備' } });
    fireEvent.click(screen.getByRole('button', { name: /選んだ2件を登録/ }));

    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith(
      'confirm-nursery-review',
      expect.objectContaining({
        intake_id: 'intake-1',
        expected_revision: 7,
        selected_items: expect.arrayContaining([
          expect.objectContaining({ review_item_id: 'item-explicit', confirmed_value: expect.objectContaining({ title: '遠足の持ち物を準備' }) }),
          expect.objectContaining({ review_item_id: 'item-ai' }),
        ]),
      }),
    ));
    const confirmCall = callEdgeFunction.mock.calls.find(([name]) => name === 'confirm-nursery-review');
    expect(confirmCall?.[1].selected_items).toHaveLength(2);
    expect(confirmCall?.[1].selected_items.some((item: { review_item_id: string }) => item.review_item_id === 'item-other')).toBe(false);
  });

  it('keeps submission Calendar off by default and sends only a human opt-in', async () => {
    callEdgeFunction.mockImplementation((name: string) => {
      if (name === 'get-nursery-review') return Promise.resolve({
        ...REVIEW,
        items: [{
          id: 'item-submission', candidate_key: 'submission', origin: 'source_explicit', item_kind: 'submission', classification: null,
          source_document_id: 'doc-1', source_page: 1, source_locator: '提出欄',
          proposed_value: { title: '遠足同意書を提出', due_date: '2026-09-22' }, confidence_band: 'high', previous_confirmed_item_id: null,
        }],
      });
      if (name === 'confirm-nursery-review') return Promise.resolve({ confirmed: true, intake_id: 'intake-1' });
      return Promise.resolve({});
    });
    renderReview();
    expect(await screen.findByRole('heading', { name: '提出物' })).toBeInTheDocument();
    const calendarChoice = screen.getByLabelText('Google Calendarにも表示する');
    expect(calendarChoice).toHaveValue('false');
    fireEvent.change(calendarChoice, { target: { value: 'true' } });
    fireEvent.click(screen.getByRole('button', { name: '選んだ1件を登録' }));

    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith(
      'confirm-nursery-review',
      expect.objectContaining({
        selected_items: [expect.objectContaining({
          review_item_id: 'item-submission',
          confirmed_value: expect.objectContaining({
            title: '遠足同意書を提出',
            due_date: '2026-09-22',
            add_to_calendar: true,
          }),
        })],
      }),
    ));
  });

  it('requires ambiguity resolution before confirmation and resolves only through the CAS endpoint', async () => {
    callEdgeFunction.mockImplementation((name: string) => {
      if (name === 'get-nursery-review') return Promise.resolve({
        ...REVIEW,
        status: 'needs_clarification', revision: 4, child_school_context_id: null,
        ambiguity_fields: ['nursery', 'child', 'class'],
      });
      if (name === 'resolve-nursery-ambiguity') return Promise.resolve({ revision: 5, status: 'review_ready' });
      return Promise.resolve({});
    });
    renderReview();
    await screen.findByRole('heading', { name: '園・子ども・クラス' });
    expect(screen.getByRole('button', { name: /選んだ2件を登録/ })).toBeDisabled();
    fireEvent.change(screen.getByLabelText('対象'), { target: { value: 'ctx-1' } });
    fireEvent.click(screen.getByRole('button', { name: 'この対象・内容で曖昧点を解消' }));
    await waitFor(() => expect(callEdgeFunction).toHaveBeenCalledWith('resolve-nursery-ambiguity', {
      intake_id: 'intake-1', expected_revision: 4, child_school_context_id: 'ctx-1', resolved_fields: ['nursery', 'child', 'class'],
    }));
  });
});
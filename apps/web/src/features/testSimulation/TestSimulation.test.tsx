import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { TestSimulation } from './TestSimulation';
import * as apiClient from '../../lib/apiClient';

vi.mock('../../lib/apiClient', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../lib/apiClient')>();
  return {
    ...actual,
    callEdgeFunction: vi.fn(),
  };
});

const callEdgeFunction = vi.mocked(apiClient.callEdgeFunction);

describe('TestSimulation', () => {
  beforeEach(() => {
    callEdgeFunction.mockReset();
  });

  it('keeps the strong TEST MODE boundary visible before starting', async () => {
    callEdgeFunction.mockResolvedValueOnce({ active: false });

    render(
      <MemoryRouter>
        <TestSimulation />
      </MemoryRouter>,
    );

    expect(await screen.findByText('🧪 TEST MODE')).toBeInTheDocument();
    expect(screen.getByText(/家族・LINE・Googleには送られません/)).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: '1人テストモード' })).toBeInTheDocument();
    expect(screen.getByLabelText('相手役')).toHaveValue('mama');
    expect(screen.getByRole('button', { name: 'テストを開始' })).toBeInTheDocument();

    await waitFor(() => {
      expect(callEdgeFunction).toHaveBeenCalledWith('test-simulation', { action: 'current' });
    });
  });

  it('shows isolated requests, tasks and synthetic deliveries for an active context', async () => {
    callEdgeFunction
      .mockResolvedValueOnce({
        active: true,
        test_context_id: '11111111-1111-4111-8111-111111111111',
        revision: 1,
        simulated_role: 'mama',
        operator_display_label: '本人',
        simulated_display_label: 'テストママ',
      })
      .mockResolvedValueOnce({
        test_context_id: '11111111-1111-4111-8111-111111111111',
        status: 'active',
        revision: 1,
        label: 'PWA 1人E2Eテスト',
        simulated_role: 'mama',
        operator_display_label: '本人',
        simulated_display_label: 'テストママ',
        production_side_effects: false,
        requests: [
          {
            request_id: '22222222-2222-4222-8222-222222222222',
            title: 'お迎えお願い',
            message: '今日はお願いします',
            due_at: null,
            status: 'pending',
            revision: 1,
            direction: 'operator_to_simulated',
            requester_side: 'operator',
            recipient_side: 'simulated',
            latest_attempt: {
              attempt_id: '33333333-3333-4333-8333-333333333333',
              attempt_kind: 'initial',
              state: 'pending',
              revision: 1,
              terms_revision: 1,
              reply_due_at: null,
            },
            linked_task_id: null,
            created_at: '2026-09-04T12:00:00Z',
          },
        ],
        tasks: [],
        deliveries: [
          {
            id: '44444444-4444-4444-8444-444444444444',
            semantic_recipient_side: 'simulated',
            channel: 'line',
            delivery_mode: 'synthetic',
            status: 'captured',
            payload: { title: 'お願い', body: 'テスト通知' },
            created_at: '2026-09-04T12:00:01Z',
          },
        ],
      });

    render(
      <MemoryRouter>
        <TestSimulation />
      </MemoryRouter>,
    );

    expect(await screen.findByText('お迎えお願い')).toBeInTheDocument();
    expect(screen.getByText(/本人（本人） → 相手役（テストママ）/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '引き受ける' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '断る' })).toBeInTheDocument();
    expect(screen.getByText(/実LINEには送らず/)).toBeInTheDocument();
    expect(screen.getByText('お願い — テスト通知')).toBeInTheDocument();
    expect(screen.getByText(/本番副作用: なし/)).toBeInTheDocument();
  });
});

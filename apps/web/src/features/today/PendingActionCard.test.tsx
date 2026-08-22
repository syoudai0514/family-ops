import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { PendingActionCard } from './PendingActionCard';
import type { PendingAction } from '../../lib/types';

function makeAction(overrides: Partial<PendingAction>): PendingAction {
  return {
    id: 'pending-1',
    action_type: 'shopping_item_add',
    normalized_payload: { title: 'オムツ', purchase_method: 'online' },
    status: 'draft',
    source: 'line',
    expires_at: '2026-08-20T12:00:00Z',
    created_at: '2026-08-20T11:00:00Z',
    ...overrides,
  };
}

function editProps() {
  return {
    onEdit: vi.fn(),
    onEditAsRequest: vi.fn().mockResolvedValue(undefined),
    onEditAsTask: vi.fn().mockResolvedValue(undefined),
  };
}

describe('PendingActionCard', () => {
  it('shows a structured preview and confirm/cancel for shopping_item_add', () => {
    const onConfirm = vi.fn().mockResolvedValue(undefined);
    const onCancel = vi.fn().mockResolvedValue(undefined);
    render(
      <ul>
        <PendingActionCard
          action={makeAction({})}
          onConfirm={onConfirm}
          onCancel={onCancel}
          {...editProps()}
        />
      </ul>,
    );
    expect(screen.getByText('オムツ')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'この内容で確定' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '編集' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'キャンセル' })).toBeInTheDocument();
    // No form-correction escape hatch for an already-structured draft.
    expect(screen.queryByRole('button', { name: 'お願いとして編集' })).not.toBeInTheDocument();
  });

  it('opens the structured edit path without confirming or cancelling', () => {
    const onEdit = vi.fn();
    const action = makeAction({
      action_type: 'task_create_once',
      normalized_payload: { title: '皮膚科の準備', scheduled_date: '2026-08-23' },
    });
    render(
      <ul>
        <PendingActionCard
          action={action}
          onConfirm={vi.fn()}
          onCancel={vi.fn()}
          {...editProps()}
          onEdit={onEdit}
        />
      </ul>,
    );
    fireEvent.click(screen.getByRole('button', { name: '編集' }));
    expect(onEdit).toHaveBeenCalledWith(action);
  });

  it('calls onConfirm with the action id when confirmed', async () => {
    const onConfirm = vi.fn().mockResolvedValue(undefined);
    render(
      <ul>
        <PendingActionCard
          action={makeAction({})}
          onConfirm={onConfirm}
          onCancel={vi.fn()}
          {...editProps()}
        />
      </ul>,
    );
    fireEvent.click(screen.getByRole('button', { name: 'この内容で確定' }));
    await waitFor(() => expect(onConfirm).toHaveBeenCalledWith('pending-1'));
  });

  it('calls onCancel with the action id when cancelled, performing no other side effect', async () => {
    const onCancel = vi.fn().mockResolvedValue(undefined);
    const onConfirm = vi.fn();
    render(
      <ul>
        <PendingActionCard
          action={makeAction({})}
          onConfirm={onConfirm}
          onCancel={onCancel}
          {...editProps()}
        />
      </ul>,
    );
    fireEvent.click(screen.getByRole('button', { name: 'キャンセル' }));
    await waitFor(() => expect(onCancel).toHaveBeenCalledWith('pending-1'));
    expect(onConfirm).not.toHaveBeenCalled();
  });

  it('needs_pwa_review offers request/task editing and cancel, never a direct confirm button', async () => {
    const onEditAsRequest = vi.fn().mockResolvedValue(undefined);
    const onEditAsTask = vi.fn().mockResolvedValue(undefined);
    const action = makeAction({
      id: 'pending-2',
      action_type: 'needs_pwa_review',
      normalized_payload: { raw_text: '来週の水曜日、保育園の準備を手伝って' },
    });
    render(
      <ul>
        <PendingActionCard
          action={action}
          onConfirm={vi.fn()}
          onCancel={vi.fn()}
          onEdit={vi.fn()}
          onEditAsRequest={onEditAsRequest}
          onEditAsTask={onEditAsTask}
        />
      </ul>,
    );
    expect(screen.getByText('来週の水曜日、保育園の準備を手伝って')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'この内容で確定' })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'お願いとして編集' }));
    await waitFor(() => expect(onEditAsRequest).toHaveBeenCalledWith(action));
    expect(onEditAsTask).not.toHaveBeenCalled();
  });

  it('shows a processing state with no action buttons once no longer draft', () => {
    render(
      <ul>
        <PendingActionCard
          action={makeAction({ status: 'confirmed' })}
          onConfirm={vi.fn()}
          onCancel={vi.fn()}
          {...editProps()}
        />
      </ul>,
    );
    expect(screen.getByText('処理中…')).toBeInTheDocument();
    expect(screen.queryByRole('button')).not.toBeInTheDocument();
  });
});

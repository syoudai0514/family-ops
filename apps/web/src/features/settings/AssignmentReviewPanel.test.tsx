import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { AssignmentReviewPanel } from './AssignmentReviewPanel';

const call = vi.fn();
vi.mock('../../lib/apiClient', async () => {
  const actual = await vi.importActual<typeof import('../../lib/apiClient')>('../../lib/apiClient');
  return { ...actual, callEdgeFunction: (...args: unknown[]) => call(...args) };
});

const initial = { transport_tentative: true, routines: [
  { definition_id: 'one', title: 'お風呂', review_suggested: true, tentative: true },
  { definition_id: 'two', title: '朝食', review_suggested: false, tentative: false },
] };

describe('private routine review', () => {
  beforeEach(() => { call.mockReset(); });
  it('shows a gentle optional review and reports tentative status to its parent', async () => {
    const loaded = vi.fn(); const changed = vi.fn();
    call.mockResolvedValue(initial);
    render(<AssignmentReviewPanel onLoaded={loaded} onChanged={changed} />);
    expect(await screen.findByText('お風呂')).toBeTruthy();
    expect(screen.queryByText('朝食')).toBeNull();
    expect(screen.getByText(/記録しないままでも大丈夫/)).toBeTruthy();
    expect(loaded).toHaveBeenCalledWith(initial);
    fireEvent.click(screen.getByRole('button', { name: 'お風呂を余裕があればにする' }));
    await waitFor(() => expect(call).toHaveBeenCalledWith('assignment-consent-review', expect.objectContaining({ action: 'optional', task_definition_id: 'one', operation_id: expect.any(String) })));
    await waitFor(() => expect(changed).toHaveBeenCalledTimes(1));
    expect(await screen.findByText('余裕があればに変更しました。')).toBeTruthy();
  });
  it('reuses the same operation after an uncertain response', async () => {
    const loaded = vi.fn(); const changed = vi.fn();
    call.mockImplementation((_name: string, body: { action: string }) => {
      if (body.action === 'read') return Promise.resolve(initial);
      const writes = call.mock.calls.filter(([, value]) => value.action === 'keep');
      return writes.length === 1 ? Promise.reject(new TypeError('connection lost')) : Promise.resolve({ ok: true });
    });
    render(<AssignmentReviewPanel onLoaded={loaded} onChanged={changed} />);
    fireEvent.click(await screen.findByRole('button', { name: 'お風呂をそのまま続ける' }));
    expect(await screen.findByRole('alert')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'お風呂をそのまま続ける' }));
    await waitFor(() => expect(changed).toHaveBeenCalledTimes(1));
    const writes = call.mock.calls.filter(([, value]) => value.action === 'keep');
    expect(writes).toHaveLength(2);
    expect(writes[0][1].operation_id).toBe(writes[1][1].operation_id);
  });
});

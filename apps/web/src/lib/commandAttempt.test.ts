import { beforeEach, describe, expect, it, vi } from 'vitest';
import { FamilyOpsApiError } from './apiClient';
import { executeCommandAttempt, loadCommandAttempt, loadStableCommandAttempt, prepareCommandAttempt, prepareStableCommandAttempt } from './commandAttempt';

describe('commandAttempt', () => {
  beforeEach(() => sessionStorage.clear());

  it('keeps the exact operation and payload after an unknown outcome', async () => {
    const attempt = prepareCommandAttempt({
      userId: 'u1', householdId: 'h1', operationId: 'op-unknown', endpoint: 'send-request',
      payload: { operation_id: 'op-unknown', recipient_user_id: 'u2', shared_message: 'お願い' },
    });
    const invoke = vi.fn().mockRejectedValue(new FamilyOpsApiError('RESULT_UNKNOWN', 'unknown', 0, undefined, 'unknown'));
    await expect(executeCommandAttempt(attempt, invoke)).rejects.toMatchObject({ outcome: 'unknown' });
    expect(loadCommandAttempt('u1', 'h1', 'op-unknown')).toMatchObject({
      state: 'unknown', endpoint: 'send-request',
      payload: { operation_id: 'op-unknown', recipient_user_id: 'u2', shared_message: 'お願い' },
    });
  });

  it('refuses same operation id with a different payload', () => {
    prepareCommandAttempt({ userId: 'u1', householdId: 'h1', operationId: 'op-conflict', endpoint: 'send-request', payload: { operation_id: 'op-conflict', shared_message: 'A' } });
    expect(() => prepareCommandAttempt({ userId: 'u1', householdId: 'h1', operationId: 'op-conflict', endpoint: 'send-request', payload: { operation_id: 'op-conflict', shared_message: 'B' } })).toThrow(/操作ID/);
  });

  it('recovers the same logical operation id after an unknown result', async () => {
    const first = prepareStableCommandAttempt({
      userId: 'u1', householdId: 'h1', logicalKey: 'request:send:u2', endpoint: 'send-request',
      buildPayload: (operationId) => ({ operation_id: operationId, recipient_user_id: 'u2', shared_message: 'A' }),
    });
    await expect(executeCommandAttempt(first, vi.fn().mockRejectedValue(new FamilyOpsApiError('RESULT_UNKNOWN', 'unknown', 0, undefined, 'unknown')))).rejects.toBeTruthy();
    const retry = prepareStableCommandAttempt({
      userId: 'u1', householdId: 'h1', logicalKey: 'request:send:u2', endpoint: 'send-request',
      buildPayload: (operationId) => ({ operation_id: operationId, recipient_user_id: 'u2', shared_message: 'A' }),
    });
    expect(retry.operationId).toBe(first.operationId);
  });

  it('keeps the logical operation link in memory when sessionStorage writes are unavailable', () => {
    const storageSpy = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new DOMException('storage blocked', 'SecurityError');
    });
    const first = prepareStableCommandAttempt({
      userId: 'u1', householdId: 'h1', logicalKey: 'request:send:u2:memory-only', endpoint: 'send-request',
      buildPayload: (operationId) => ({ operation_id: operationId, recipient_user_id: 'u2', shared_message: 'A' }),
    });
    const retry = prepareStableCommandAttempt({
      userId: 'u1', householdId: 'h1', logicalKey: 'request:send:u2:memory-only', endpoint: 'send-request',
      buildPayload: (operationId) => ({ operation_id: operationId, recipient_user_id: 'u2', shared_message: 'A' }),
    });
    expect(retry.operationId).toBe(first.operationId);
    expect(loadStableCommandAttempt('u1', 'h1', 'request:send:u2:memory-only')?.operationId).toBe(first.operationId);
    storageSpy.mockRestore();
  });

  it('does not expose an attempt to another user or household', () => {
    prepareCommandAttempt({ userId: 'u1', householdId: 'h1', operationId: 'op-privacy', endpoint: 'send-request', payload: { operation_id: 'op-privacy' } });
    expect(loadCommandAttempt('u2', 'h1', 'op1')).toBeNull();
    expect(loadCommandAttempt('u1', 'h2', 'op1')).toBeNull();
  });
});

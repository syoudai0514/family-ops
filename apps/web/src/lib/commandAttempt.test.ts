import { beforeEach, describe, expect, it, vi } from 'vitest';
import { FamilyOpsApiError } from './apiClient';
import { executeCommandAttempt, loadCommandAttempt, prepareCommandAttempt, prepareStableCommandAttempt } from './commandAttempt';

describe('commandAttempt', () => {
  beforeEach(() => sessionStorage.clear());

  it('keeps the exact operation and payload after an unknown outcome', async () => {
    const attempt = prepareCommandAttempt({
      userId: 'u1', householdId: 'h1', operationId: 'op1', endpoint: 'send-request',
      payload: { operation_id: 'op1', recipient_user_id: 'u2', shared_message: 'お願い' },
    });
    const invoke = vi.fn().mockRejectedValue(new FamilyOpsApiError('RESULT_UNKNOWN', 'unknown', 0, undefined, 'unknown'));
    await expect(executeCommandAttempt(attempt, invoke)).rejects.toMatchObject({ outcome: 'unknown' });
    expect(loadCommandAttempt('u1', 'h1', 'op1')).toMatchObject({
      state: 'unknown', endpoint: 'send-request',
      payload: { operation_id: 'op1', recipient_user_id: 'u2', shared_message: 'お願い' },
    });
  });

  it('refuses same operation id with a different payload', () => {
    prepareCommandAttempt({ userId: 'u1', householdId: 'h1', operationId: 'op1', endpoint: 'send-request', payload: { operation_id: 'op1', shared_message: 'A' } });
    expect(() => prepareCommandAttempt({ userId: 'u1', householdId: 'h1', operationId: 'op1', endpoint: 'send-request', payload: { operation_id: 'op1', shared_message: 'B' } })).toThrow(/操作ID/);
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

  it('does not expose an attempt to another user or household', () => {
    prepareCommandAttempt({ userId: 'u1', householdId: 'h1', operationId: 'op1', endpoint: 'send-request', payload: { operation_id: 'op1' } });
    expect(loadCommandAttempt('u2', 'h1', 'op1')).toBeNull();
    expect(loadCommandAttempt('u1', 'h2', 'op1')).toBeNull();
  });
});

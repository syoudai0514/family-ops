import { useCallback, useRef } from 'react';
import { useAuth } from '../app/AuthContext';
import { useHousehold } from '../app/HouseholdContext';
import type { EdgeFunctionName } from './edgeFunctions';
import { executeCommandAttempt, prepareStableCommandAttempt } from './commandAttempt';
import { FamilyOpsApiError } from './apiClient';

export function useCommandAttempt() {
  const { user } = useAuth();
  const { household } = useHousehold();
  const running = useRef(new Set<string>());

  return useCallback(async <T,>(
    logicalKey: string,
    endpoint: EdgeFunctionName,
    buildPayload: (operationId: string) => Record<string, unknown>,
  ): Promise<T> => {
    if (!user || !household) {
      throw new FamilyOpsApiError('NOT_READY', '家庭情報を確認できません。再読み込みしてください。', 0, undefined, 'not_sent');
    }
    const guard = `${endpoint}:${logicalKey}`;
    if (running.current.has(guard)) {
      throw new FamilyOpsApiError('ALREADY_SENDING', '同じ操作を確認中です。', 0, undefined, 'not_sent');
    }
    running.current.add(guard);
    try {
      const attempt = prepareStableCommandAttempt({
        userId: user.id,
        householdId: household.id,
        logicalKey,
        endpoint,
        buildPayload,
      });
      return await executeCommandAttempt<T>(attempt);
    } finally {
      running.current.delete(guard);
    }
  }, [household, user]);
}

import { FamilyOpsApiError, callEdgeFunction } from './apiClient';
import type { EdgeFunctionName } from './edgeFunctions';

export type CommandAttemptState = 'prepared' | 'sending' | 'unknown' | 'succeeded' | 'rejected';

export type CommandAttempt = {
  version: 1;
  userId: string;
  householdId: string;
  operationId: string;
  endpoint: EdgeFunctionName;
  payload: Readonly<Record<string, unknown>>;
  state: CommandAttemptState;
  createdAt: string;
  result?: { entityId?: string; status?: string };
  logicalKey?: string;
};

const PREFIX = 'family-ops:command-attempt:v1';
const RESUME_MS = 24 * 60 * 60 * 1000;
const memory = new Map<string, CommandAttempt>();
const linkMemory = new Map<string, string>();

function linkKey(userId: string, householdId: string, logicalKey: string) {
  return `${PREFIX}:link:${userId}:${householdId}:${encodeURIComponent(logicalKey)}`;
}

function readLinkedOperationId(userId: string, householdId: string, logicalKey: string): string | null {
  const key = linkKey(userId, householdId, logicalKey);
  try { return sessionStorage.getItem(key) ?? linkMemory.get(key) ?? null; } catch { return linkMemory.get(key) ?? null; }
}

function writeLink(attempt: CommandAttempt) {
  if (!attempt.logicalKey) return;
  const key = linkKey(attempt.userId, attempt.householdId, attempt.logicalKey);
  linkMemory.set(key, attempt.operationId);
  try { sessionStorage.setItem(key, attempt.operationId); } catch { /* memory-only link */ }
}

function removeLink(attempt: CommandAttempt) {
  if (!attempt.logicalKey) return;
  const key = linkKey(attempt.userId, attempt.householdId, attempt.logicalKey);
  linkMemory.delete(key);
  try { sessionStorage.removeItem(key); } catch { /* no-op */ }
}

function keyFor(userId: string, householdId: string, operationId: string) {
  return `${PREFIX}:${userId}:${householdId}:${operationId}`;
}

function normalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(normalize);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map(([key, child]) => [key, normalize(child)]));
  }
  return value;
}

function samePayload(a: Readonly<Record<string, unknown>>, b: Readonly<Record<string, unknown>>) {
  return JSON.stringify(normalize(a)) === JSON.stringify(normalize(b));
}

function persist(attempt: CommandAttempt) {
  const key = keyFor(attempt.userId, attempt.householdId, attempt.operationId);
  memory.set(key, attempt);
  try { sessionStorage.setItem(key, JSON.stringify(attempt)); } catch { /* memory fallback */ }
  writeLink(attempt);
}

function remove(attempt: CommandAttempt) {
  const key = keyFor(attempt.userId, attempt.householdId, attempt.operationId);
  memory.delete(key);
  try { sessionStorage.removeItem(key); } catch { /* memory fallback */ }
  removeLink(attempt);
}

export function loadCommandAttempt(userId: string, householdId: string, operationId: string): CommandAttempt | null {
  const key = keyFor(userId, householdId, operationId);
  let value = memory.get(key) ?? null;
  if (!value) {
    try {
      const raw = sessionStorage.getItem(key);
      value = raw ? JSON.parse(raw) as CommandAttempt : null;
    } catch { value = null; }
  }
  if (!value || value.version !== 1 || value.userId !== userId || value.householdId !== householdId || value.operationId !== operationId) return null;
  const age = Date.now() - new Date(value.createdAt).getTime();
  if (!Number.isFinite(age) || age < 0 || age > RESUME_MS) {
    remove(value);
    return null;
  }
  return value;
}

export function loadStableCommandAttempt(userId: string, householdId: string, logicalKey: string): CommandAttempt | null {
  const operationId = readLinkedOperationId(userId, householdId, logicalKey);
  return operationId ? loadCommandAttempt(userId, householdId, operationId) : null;
}

export function prepareCommandAttempt(input: Omit<CommandAttempt, 'version' | 'state' | 'createdAt'>): CommandAttempt {
  const existing = loadCommandAttempt(input.userId, input.householdId, input.operationId);
  if (existing) {
    if (existing.endpoint !== input.endpoint || !samePayload(existing.payload, input.payload)) {
      throw new FamilyOpsApiError('IDEMPOTENCY_CONFLICT', '同じ操作IDで内容が変わっています。最新状態から確認し直してください。', 409, undefined, 'rejected');
    }
    return existing;
  }
  const operationInPayload = input.payload.operation_id;
  if (operationInPayload !== input.operationId) {
    throw new FamilyOpsApiError('INVALID_ATTEMPT', 'operation_id と確定操作が一致しません。', 0, undefined, 'not_sent');
  }
  const attempt: CommandAttempt = { ...input, version: 1, state: 'prepared', createdAt: new Date().toISOString() };
  persist(attempt);
  return attempt;
}

export function prepareStableCommandAttempt(input: {
  userId: string;
  householdId: string;
  logicalKey: string;
  endpoint: EdgeFunctionName;
  buildPayload: (operationId: string) => Readonly<Record<string, unknown>>;
}): CommandAttempt {
  const linkedOperationId = readLinkedOperationId(input.userId, input.householdId, input.logicalKey);
  const operationId = linkedOperationId ?? crypto.randomUUID();
  return prepareCommandAttempt({
    userId: input.userId,
    householdId: input.householdId,
    operationId,
    logicalKey: input.logicalKey,
    endpoint: input.endpoint,
    payload: input.buildPayload(operationId),
  });
}

export async function executeCommandAttempt<T>(
  attempt: CommandAttempt,
  invoke: (endpoint: EdgeFunctionName, payload: Record<string, unknown>) => Promise<T> = (endpoint, payload) => callEdgeFunction<T>(endpoint, payload),
): Promise<T> {
  const sending = { ...attempt, state: 'sending' as const };
  persist(sending);
  try {
    const value = await invoke(attempt.endpoint, { ...attempt.payload });
    remove(attempt);
    return value;
  } catch (error) {
    if (error instanceof FamilyOpsApiError && error.outcome === 'unknown') {
      persist({ ...attempt, state: 'unknown' });
    } else {
      remove(attempt);
    }
    throw error;
  }
}

export function discardCommandAttempt(attempt: CommandAttempt) {
  remove(attempt);
}

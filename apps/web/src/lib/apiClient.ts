import { getAppEnv } from './env';
import { supabase } from './supabaseClient';
import type { EdgeFunctionName } from './edgeFunctions';
import { REQUEST_DEADLINES_MS, requestPolicyFor, type RequestPolicyKind } from './requestPolicy';

export interface ApiErrorEnvelope {
  error: {
    code: string;
    message: string;
    detail?: unknown;
  };
}

export type ApiOutcome = 'not_sent' | 'unknown' | 'rejected';

export class FamilyOpsApiError extends Error {
  readonly code: string;
  readonly status: number;
  readonly detail?: unknown;
  readonly outcome: ApiOutcome;

  constructor(code: string, message: string, status: number, detail?: unknown, outcome: ApiOutcome = 'rejected') {
    super(message);
    this.name = 'FamilyOpsApiError';
    this.code = code;
    this.status = status;
    this.detail = detail;
    this.outcome = outcome;
  }
}

function isApiErrorEnvelope(value: unknown): value is ApiErrorEnvelope {
  if (typeof value !== 'object' || value === null) return false;
  const err = (value as Record<string, unknown>).error;
  if (typeof err !== 'object' || err === null) return false;
  const rec = err as Record<string, unknown>;
  return typeof rec.code === 'string' && typeof rec.message === 'string';
}

class PhaseTimeoutError extends Error {
  readonly phase: 'auth' | 'fetch' | 'body';

  constructor(phase: 'auth' | 'fetch' | 'body') {
    super(`${phase} deadline exceeded`);
    this.name = 'PhaseTimeoutError';
    this.phase = phase;
  }
}

async function within<T>(promise: PromiseLike<T>, ms: number, phase: 'auth' | 'fetch' | 'body', onTimeout?: () => void): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      onTimeout?.();
      reject(new PhaseTimeoutError(phase));
    }, ms);
    Promise.resolve(promise).then(
      (value) => {
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        reject(error);
      },
    );
  });
}

export type CallEdgeFunctionOptions = {
  policy?: RequestPolicyKind;
};

function unknownOutcome(message = '送信結果を確認できませんでした。同じ操作の結果を確認してください。') {
  return new FamilyOpsApiError('RESULT_UNKNOWN', message, 0, undefined, 'unknown');
}

export async function callEdgeFunction<T>(
  name: EdgeFunctionName,
  body: object,
  options: CallEdgeFunctionOptions = {},
): Promise<T> {
  const { supabaseUrl, supabasePublishableKey } = getAppEnv();
  let sessionData: Awaited<ReturnType<typeof supabase.auth.getSession>>['data'];
  try {
    const session = await within(supabase.auth.getSession(), REQUEST_DEADLINES_MS.auth, 'auth');
    sessionData = session.data;
  } catch (error) {
    if (error instanceof PhaseTimeoutError) {
      throw new FamilyOpsApiError('AUTH_TIMEOUT', '認証確認に時間がかかっています。送信は開始していません。', 0, undefined, 'not_sent');
    }
    throw error;
  }
  const accessToken = sessionData.session?.access_token;
  if (!accessToken) {
    throw new FamilyOpsApiError('NOT_AUTHENTICATED', 'No active session.', 401, undefined, 'not_sent');
  }

  const policy = options.policy ?? requestPolicyFor(name);
  const deadlineMs = REQUEST_DEADLINES_MS[policy];
  const controller = new AbortController();
  const startedAt = Date.now();
  let response: Response;
  try {
    response = await within(
      fetch(`${supabaseUrl}/functions/v1/${name}`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${accessToken}`,
          apikey: supabasePublishableKey,
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      }),
      deadlineMs,
      'fetch',
      () => controller.abort(),
    );
  } catch (error) {
    if (error instanceof PhaseTimeoutError || error instanceof DOMException || error instanceof TypeError) {
      throw policy === 'mutation'
        ? unknownOutcome()
        : new FamilyOpsApiError('NETWORK_ERROR', 'サーバーへ接続できませんでした。', 0, undefined, 'not_sent');
    }
    throw error;
  }

  const elapsed = Date.now() - startedAt;
  const remainingMs = Math.max(1, deadlineMs - elapsed);
  let text: string;
  try {
    text = await within(response.text(), remainingMs, 'body', () => controller.abort());
  } catch {
    throw policy === 'mutation'
      ? unknownOutcome()
      : new FamilyOpsApiError('NETWORK_ERROR', '応答を最後まで読み込めませんでした。', 0, undefined, 'not_sent');
  }

  let payload: unknown = null;
  if (text.length > 0) {
    try {
      payload = JSON.parse(text);
    } catch {
      if (response.ok && policy === 'mutation') throw unknownOutcome('送信結果の形式を確認できませんでした。同じ操作の結果を確認してください。');
      payload = null;
    }
  }

  if (!response.ok) {
    if (isApiErrorEnvelope(payload)) {
      const outcome: ApiOutcome = response.status >= 500 ? 'unknown' : 'rejected';
      throw new FamilyOpsApiError(payload.error.code, payload.error.message, response.status, payload.error.detail, outcome);
    }
    if (response.status >= 500 && policy === 'mutation') {
      throw unknownOutcome(`サーバー応答（${response.status}）だけでは送信結果を確定できません。同じ操作の結果を確認してください。`);
    }
    throw new FamilyOpsApiError('UNKNOWN_ERROR', `Request failed with status ${response.status}.`, response.status, undefined, 'rejected');
  }

  if (policy === 'mutation' && text.length > 0 && payload === null) {
    throw unknownOutcome();
  }
  return payload as T;
}

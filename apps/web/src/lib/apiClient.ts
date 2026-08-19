import { getAppEnv } from './env';
import { supabase } from './supabaseClient';
import type { EdgeFunctionName } from './edgeFunctions';

export interface ApiErrorEnvelope {
  error: {
    code: string;
    message: string;
    detail?: unknown;
  };
}

// Thrown for every non-2xx Edge Function response. `code` is the backend's
// stable error code (e.g. "TASK_TERMINAL"), so callers can branch on it
// instead of parsing `message` strings.
export class FamilyOpsApiError extends Error {
  readonly code: string;
  readonly status: number;
  readonly detail?: unknown;

  constructor(code: string, message: string, status: number, detail?: unknown) {
    super(message);
    this.name = 'FamilyOpsApiError';
    this.code = code;
    this.status = status;
    this.detail = detail;
  }
}

function isApiErrorEnvelope(value: unknown): value is ApiErrorEnvelope {
  if (typeof value !== 'object' || value === null) return false;
  const err = (value as Record<string, unknown>).error;
  if (typeof err !== 'object' || err === null) return false;
  const rec = err as Record<string, unknown>;
  return typeof rec.code === 'string' && typeof rec.message === 'string';
}

// POSTs to `${VITE_SUPABASE_URL}/functions/v1/<name>` with the caller's JWT
// and the publishable apikey, JSON-encodes `body`, and throws a typed
// FamilyOpsApiError on any non-2xx response. Every mutation screen should
// route its Edge Function calls through this helper rather than hand-rolling
// fetch — it's the one place auth headers and error parsing live.
export async function callEdgeFunction<T>(name: EdgeFunctionName, body: object): Promise<T> {
  const { supabaseUrl, supabasePublishableKey } = getAppEnv();
  const { data: sessionData } = await supabase.auth.getSession();
  const accessToken = sessionData.session?.access_token;

  if (!accessToken) {
    throw new FamilyOpsApiError('NOT_AUTHENTICATED', 'No active session.', 401);
  }

  let response: Response;
  try {
    response = await fetch(`${supabaseUrl}/functions/v1/${name}`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${accessToken}`,
        apikey: supabasePublishableKey,
      },
      body: JSON.stringify(body),
    });
  } catch {
    throw new FamilyOpsApiError('NETWORK_ERROR', 'Could not reach the server. Check your connection.', 0);
  }

  let payload: unknown = null;
  const text = await response.text();
  if (text.length > 0) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = null;
    }
  }

  if (!response.ok) {
    if (isApiErrorEnvelope(payload)) {
      throw new FamilyOpsApiError(
        payload.error.code,
        payload.error.message,
        response.status,
        payload.error.detail,
      );
    }
    throw new FamilyOpsApiError(
      'UNKNOWN_ERROR',
      `Request failed with status ${response.status}.`,
      response.status,
    );
  }

  return payload as T;
}

// Thin wrapper around supabase-js .rpc() calls to public.server_tx_* so every
// user-mutation function translates a raised Postgres exception (our
// server_tx_* functions raise the bare error code as the exception message,
// e.g. "HOUSEHOLD_FULL") into the same typed FamilyOpsError uniformly.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { describeCode, FamilyOpsError, isKnownErrorCode, statusForCode } from "./errors.ts";

export async function callServerTx<T = unknown>(
  client: SupabaseClient,
  fnName: string,
  args: Record<string, unknown>,
): Promise<T> {
  const { data, error } = await client.rpc(fnName, args);
  if (error) {
    // Our server_tx_* functions raise the error code as the bare exception
    // message (e.g. `raise exception 'HOUSEHOLD_FULL';`); some drivers may
    // instead surface a structured detail (used for INVITE_TOKEN_ALREADY_ISSUED's
    // existing invite id). Either way, only a recognized code is ever
    // forwarded to the client — anything else becomes a generic 500 so
    // internal Postgres detail never leaks.
    const code = error.message?.trim() ?? "";
    if (isKnownErrorCode(code)) {
      const detail = (error as { details?: string }).details?.trim() || undefined;
      throw new FamilyOpsError(code, describeCode(code), statusForCode(code), detail);
    }
    console.error("server_tx RPC failed", { fnName, message: error.message });
    throw new FamilyOpsError("INTERNAL_ERROR", "内部エラーが発生しました", 500);
  }
  return data as T;
}

// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #0: every client mutation
// requires an operation_id; missing/invalid => INVALID_INPUT before any RPC.
export function requireOperationId(body: Record<string, unknown>): string {
  const operationId = body["operation_id"];
  if (typeof operationId !== "string" || operationId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "operation_id is required", 400);
  }
  return operationId;
}

export async function readJsonBody(req: Request): Promise<Record<string, unknown>> {
  try {
    const body = await req.json();
    if (typeof body !== "object" || body === null) {
      throw new Error("not an object");
    }
    return body as Record<string, unknown>;
  } catch {
    throw new FamilyOpsError("INVALID_INPUT", "invalid JSON body", 400);
  }
}

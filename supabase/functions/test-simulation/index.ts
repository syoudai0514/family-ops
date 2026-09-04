import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import {
  describeCode,
  FamilyOpsError,
  isKnownErrorCode,
  statusForCode,
} from "../_shared/errors.ts";
import { jsonResponse, withUserMutationHandler } from "../_shared/handler.ts";
import { readJsonBody, requireOperationId } from "../_shared/rpc.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const SIMULATION_ERRORS: Record<string, { status: number; message: string }> = {
  TEST_SIMULATION_CAPABILITY_NOT_ENABLED: { status: 409, message: "1人テストモードはまだ有効になっていません" },
  TEST_SIMULATION_ALREADY_ACTIVE: { status: 409, message: "すでに1人テストモードが開始されています" },
  SIMULATED_ROLE_INVALID: { status: 400, message: "相手役を選択してください" },
  TEST_SIMULATION_LABEL_INVALID: { status: 400, message: "テスト名が長すぎます" },
  TEST_CONTEXT_NOT_FOUND: { status: 404, message: "テストが見つかりません" },
  TEST_CONTEXT_OPERATOR_MISMATCH: { status: 403, message: "このテストを操作する権限がありません" },
  TEST_CONTEXT_NOT_ACTIVE: { status: 409, message: "このテストはすでに終了しています" },
  TEST_SIMULATION_DIRECTION_INVALID: { status: 400, message: "お願いの向きを選択してください" },
  TEST_SIMULATION_REQUEST_INPUT_INVALID: { status: 400, message: "お願いの内容を確認してください" },
  TEST_SIMULATION_REQUEST_ACTION_INVALID: { status: 400, message: "お願いへの操作を確認してください" },
  TEST_SIMULATION_REQUEST_NOT_FOUND: { status: 404, message: "テストのお願いが見つかりません" },
  TEST_SIMULATION_REQUEST_SCOPE_INVALID: { status: 403, message: "テスト外のお願いは操作できません" },
  TEST_SIMULATION_TASK_NOT_FOUND: { status: 404, message: "テストのタスクが見つかりません" },
  TEST_SIMULATION_TASK_SCOPE_INVALID: { status: 403, message: "テスト外のタスクは操作できません" },
  ACTOR_REF_NOT_FOUND: { status: 500, message: "テスト用の本人情報を準備できませんでした" },
  SIMULATED_ACTOR_REF_NOT_FOUND: { status: 500, message: "テスト相手役を準備できませんでした" },
};

async function callSimulationRpc<T = unknown>(
  client: SupabaseClient,
  fnName: string,
  args: Record<string, unknown>,
): Promise<T> {
  const { data, error } = await client.rpc(fnName, args);
  if (!error) return data as T;

  const code = error.message?.trim() ?? "";
  const simulationError = SIMULATION_ERRORS[code];
  if (simulationError) {
    throw new FamilyOpsError(code, simulationError.message, simulationError.status);
  }
  if (isKnownErrorCode(code)) {
    const detail = (error as { details?: string }).details?.trim() || undefined;
    throw new FamilyOpsError(code, describeCode(code), statusForCode(code), detail);
  }

  console.error("test-simulation RPC failed", { fnName, message: error.message });
  throw new FamilyOpsError("INTERNAL_ERROR", "内部エラーが発生しました", 500);
}

function requiredUuid(body: Record<string, unknown>, key: string): string {
  const value = body[key];
  if (typeof value !== "string" || !UUID_RE.test(value)) {
    throw new FamilyOpsError("INVALID_INPUT", `${key} is invalid`, 400);
  }
  return value;
}

function requiredString(body: Record<string, unknown>, key: string): string {
  const value = body[key];
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", `${key} is required`, 400);
  }
  return value.trim();
}

function requiredInteger(body: Record<string, unknown>, key: string): number {
  const value = body[key];
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1) {
    throw new FamilyOpsError("INVALID_INPUT", `${key} is invalid`, 400);
  }
  return value;
}

Deno.serve(withUserMutationHandler(async (req) => {
  if (req.method !== "POST") {
    throw new FamilyOpsError("INVALID_INPUT", "POST required", 400);
  }

  // Security invariant: resolve the real authenticated operator using the
  // caller JWT before a service-role client exists. The browser never sends an
  // ActorRef id; DB RPCs derive both the operator and simulated ActorRefs.
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const action = requiredString(body, "action");
  const service = createServiceRoleClient();

  if (action === "current") {
    const result = await callSimulationRpc(service, "server_tx_get_active_test_simulation_v1", {
      p_actor_id: actorId,
    });
    return jsonResponse(result);
  }

  if (action === "open") {
    const operationId = requireOperationId(body);
    const simulatedRole = requiredString(body, "simulated_role");
    if (simulatedRole !== "mama" && simulatedRole !== "papa") {
      throw new FamilyOpsError("SIMULATED_ROLE_INVALID", "相手役を選択してください", 400);
    }
    const label = typeof body.label === "string" ? body.label.trim() || null : null;
    const result = await callSimulationRpc(service, "server_tx_open_test_simulation_interactive_v1", {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_simulated_role: simulatedRole,
      p_label: label,
    });
    return jsonResponse(result);
  }

  const testContextId = requiredUuid(body, "test_context_id");

  if (action === "workspace") {
    const result = await callSimulationRpc(service, "server_tx_get_test_simulation_workspace_v2", {
      p_actor_id: actorId,
      p_test_context_id: testContextId,
    });
    return jsonResponse(result);
  }

  if (action === "send_request") {
    const operationId = requireOperationId(body);
    const direction = requiredString(body, "direction");
    const title = requiredString(body, "title");
    const message = typeof body.message === "string" ? body.message.trim() || null : null;
    const dueAt = typeof body.due_at === "string" && body.due_at.length > 0 ? body.due_at : null;
    const result = await callSimulationRpc(service, "server_tx_test_simulation_send_request_v1", {
      p_actor_id: actorId,
      p_test_context_id: testContextId,
      p_operation_id: operationId,
      p_direction: direction,
      p_shared_title: title,
      p_shared_message: message,
      p_due_at: dueAt,
    });
    return jsonResponse(result);
  }

  if (action === "respond_request") {
    const operationId = requireOperationId(body);
    const responseAction = requiredString(body, "response_action");
    if (responseAction !== "accept" && responseAction !== "decline") {
      throw new FamilyOpsError("TEST_SIMULATION_REQUEST_ACTION_INVALID", "応答操作が不正です", 400);
    }
    const result = await callSimulationRpc(service, "server_tx_test_simulation_respond_request_v1", {
      p_actor_id: actorId,
      p_test_context_id: testContextId,
      p_operation_id: operationId,
      p_request_id: requiredUuid(body, "request_id"),
      p_attempt_id: requiredUuid(body, "attempt_id"),
      p_action: responseAction,
      p_expected_revision: requiredInteger(body, "expected_revision"),
      p_expected_terms_revision: requiredInteger(body, "expected_terms_revision"),
    });
    return jsonResponse(result);
  }

  if (action === "complete_task") {
    const operationId = requireOperationId(body);
    const result = await callSimulationRpc(service, "server_tx_test_simulation_complete_task_v1", {
      p_actor_id: actorId,
      p_test_context_id: testContextId,
      p_operation_id: operationId,
      p_task_id: requiredUuid(body, "task_id"),
      p_expected_revision: requiredInteger(body, "expected_revision"),
    });
    return jsonResponse(result);
  }

  if (action === "archive") {
    const operationId = requireOperationId(body);
    const result = await callSimulationRpc(service, "server_tx_archive_test_simulation_interactive_v1", {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_test_context_id: testContextId,
      p_expected_revision: requiredInteger(body, "expected_revision"),
    });
    return jsonResponse(result);
  }

  throw new FamilyOpsError("INVALID_INPUT", "unknown action", 400);
}));

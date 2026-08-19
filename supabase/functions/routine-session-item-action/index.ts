// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md #8 "項目ごとに入力" per-item
// actions (`action`: 'complete' | 'partner_handled' | 'skip'). `source` is
// always 'pwa' here — see complete-routine-session's header comment for the
// LINE-postback wiring note.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

const ALLOWED_ACTIONS = new Set(["complete", "partner_handled", "skip"]);

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const sessionId = body["session_id"];
  if (typeof sessionId !== "string" || sessionId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "session_id is required", 400);
  }
  const taskInstanceId = body["task_instance_id"];
  if (typeof taskInstanceId !== "string" || taskInstanceId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "task_instance_id is required", 400);
  }
  const action = body["action"];
  if (typeof action !== "string" || !ALLOWED_ACTIONS.has(action)) {
    throw new FamilyOpsError("INVALID_INPUT", "action must be complete, partner_handled, or skip", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx(
    serviceClient,
    "server_tx_routine_session_item_action",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_session_id: sessionId,
      p_task_instance_id: taskInstanceId,
      p_action: action,
      p_source: "pwa",
    },
  );

  return jsonResponse(result);
}));

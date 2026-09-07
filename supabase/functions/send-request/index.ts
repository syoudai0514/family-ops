// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const recipientUserId = body["recipient_user_id"];
  const sharedTitle = body["shared_title"];
  if (typeof recipientUserId !== "string" || recipientUserId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "recipient_user_id is required", 400);
  }
  if (typeof sharedTitle !== "string" || sharedTitle.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "shared_title is required", 400);
  }

  const serviceClient = createServiceRoleClient();
  const sharedMessage = typeof body["shared_message"] === "string" ? body["shared_message"] : null;
  const dueAt = typeof body["due_at"] === "string" ? body["due_at"] : null;
  const replyDueAt = typeof body["reply_due_at"] === "string" ? body["reply_due_at"] : null;
  const result = replyDueAt
    ? await callServerTx<{ request_id: string }>(serviceClient, "server_tx_send_request_v2", {
        p_actor_id: actorId,
        p_operation_id: operationId,
        p_recipient_user_id: recipientUserId,
        p_shared_title: sharedTitle,
        p_shared_message: sharedMessage,
        p_due_at: dueAt,
        p_reply_due_at: replyDueAt,
      })
    : await callServerTx<{ request_id: string }>(serviceClient, "server_tx_send_request", {
        p_actor_id: actorId,
        p_operation_id: operationId,
        p_recipient_user_id: recipientUserId,
        p_shared_title: sharedTitle,
        p_shared_message: sharedMessage,
        p_due_at: dueAt,
      });

  return jsonResponse(result);
}));

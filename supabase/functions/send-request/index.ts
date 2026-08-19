// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md request section "send-request".
// WP5 (Gemini AI rewrite/confirm-request-draft) is out of scope — this
// accepts directly user-typed shared_title/shared_message only.
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
  const result = await callServerTx<{ request_id: string }>(
    serviceClient,
    "server_tx_send_request",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_recipient_user_id: recipientUserId,
      p_shared_title: sharedTitle,
      p_shared_message: typeof body["shared_message"] === "string" ? body["shared_message"] : null,
      p_due_at: typeof body["due_at"] === "string" ? body["due_at"] : null,
    },
  );

  return jsonResponse(result);
}));

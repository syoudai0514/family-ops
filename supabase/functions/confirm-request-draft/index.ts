// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #13 "AI rewrite
// confirmation" — confirm-request-draft. Accepts the raw_input id plus the
// user's FINAL confirmed text (their own edit of the AI proposal, not
// necessarily the AI's raw output verbatim) and writes the real
// public.requests row via server_tx_confirm_request_draft, which delegates
// to the existing WP2 server_tx_send_request logic under a derived
// sub-operation-id (see docs/adr/0003-ai-draft-propose-endpoint.md).
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const rawInputId = body["raw_input_id"];
  const recipientUserId = body["recipient_user_id"];
  const sharedTitle = body["shared_title"];
  const confirmedMessage = body["confirmed_message"];
  if (typeof rawInputId !== "string" || rawInputId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "raw_input_id is required", 400);
  }
  if (typeof recipientUserId !== "string" || recipientUserId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "recipient_user_id is required", 400);
  }
  if (typeof sharedTitle !== "string" || sharedTitle.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "shared_title is required", 400);
  }
  if (typeof confirmedMessage !== "string" || confirmedMessage.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "confirmed_message is required", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{ request_id: string }>(
    serviceClient,
    "server_tx_confirm_request_draft",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_raw_input_id: rawInputId,
      p_recipient_user_id: recipientUserId,
      p_shared_title: sharedTitle,
      p_confirmed_message: confirmedMessage,
      p_due_at: typeof body["due_at"] === "string" ? body["due_at"] : null,
    },
  );

  return jsonResponse(result);
}));

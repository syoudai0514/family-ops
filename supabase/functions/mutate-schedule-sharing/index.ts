// verify_jwt=true. Business metadata goes through a household-scoped transaction.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { jsonResponse, withUserMutationHandler } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  if (typeof body.task_id !== "string" || !["register_attachment", "delete_attachment", "add_comment"].includes(String(body.action))) {
    throw new FamilyOpsError("INVALID_INPUT", "task_id and action are required", 400);
  }
  const client = createServiceRoleClient();
  const result = await callServerTx<{ object_path?: string }>(client, "server_tx_mutate_schedule_sharing", {
    p_actor_id: actorId, p_operation_id: operationId, p_task_id: body.task_id,
    p_action: body.action, p_payload: body,
  });
  if (body.action === "delete_attachment" && result.object_path) {
    const { error } = await client.storage.from("schedule-attachments").remove([result.object_path]);
    if (error) throw new FamilyOpsError("INTERNAL_ERROR", "添付の削除を再試行してください。", 500);
  }
  return jsonResponse(result);
}));

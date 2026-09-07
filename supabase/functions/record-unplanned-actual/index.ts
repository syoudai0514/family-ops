// Issue #54: authenticated, human-confirmed, atomic unplanned-actual entry.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  const title = body["title"];
  const scheduledDate = body["scheduled_date"];

  if (typeof title !== "string" || title.trim().length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "title is required", 400);
  }
  if (typeof scheduledDate !== "string" || !ISO_DATE.test(scheduledDate)) {
    throw new FamilyOpsError("INVALID_INPUT", "scheduled_date must be YYYY-MM-DD", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{
    task_id: string;
    status: "completed";
    scheduled_date: string;
    completed_at: string;
  }>(serviceClient, "server_tx_record_unplanned_actual", {
    p_actor_id: actorId,
    p_operation_id: operationId,
    p_title: title.trim(),
    p_scheduled_date: scheduledDate,
  });

  return jsonResponse(result);
}));

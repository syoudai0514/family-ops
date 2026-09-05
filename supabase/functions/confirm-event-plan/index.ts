// Q17: this is the only Event-planning endpoint that creates canonical rows.
// The client submits the human-reviewed event fields and only the Todo
// candidates the user explicitly kept.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import { jsonResponse, withUserMutationHandler } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  if (typeof body.draft_id !== "string" || typeof body.expected_revision !== "number") {
    throw new FamilyOpsError("INVALID_INPUT", "下書き情報が不正です", 400);
  }
  if (typeof body.reviewed_event !== "object" || body.reviewed_event === null || Array.isArray(body.reviewed_event)) {
    throw new FamilyOpsError("INVALID_INPUT", "イベント内容を確認してください", 400);
  }
  if (!Array.isArray(body.selected_todos)) {
    throw new FamilyOpsError("INVALID_INPUT", "準備ToDoを確認してください", 400);
  }
  return jsonResponse(await callServerTx(createServiceRoleClient(), "server_tx_confirm_event_planning_draft", {
    p_actor_id: actorId,
    p_operation_id: operationId,
    p_draft_id: body.draft_id,
    p_expected_revision: body.expected_revision,
    p_reviewed_event: body.reviewed_event,
    p_selected_todos: body.selected_todos,
  }));
}));

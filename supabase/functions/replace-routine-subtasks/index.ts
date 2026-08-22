// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

function validSubtasks(value: unknown): boolean {
  return Array.isArray(value) && value.every((item) =>
    typeof item === 'object' && item !== null && typeof (item as Record<string, unknown>).title === 'string'
  );
}

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const taskDefinitionId = body['task_definition_id'];
  const subtasks = body['subtasks'];
  if (typeof taskDefinitionId !== 'string' || !validSubtasks(subtasks)) {
    throw new FamilyOpsError('INVALID_INPUT', 'task_definition_id and subtasks are required', 400);
  }
  return jsonResponse(await callServerTx(createServiceRoleClient(), 'server_tx_replace_routine_subtasks', {
    p_actor_id: actorId,
    p_operation_id: requireOperationId(body),
    p_task_definition_id: taskDefinitionId,
    p_subtasks: subtasks,
  }));
}));

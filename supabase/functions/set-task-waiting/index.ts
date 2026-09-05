// verify_jwt=true. Waiting is an active task state, never a completion or a
// hidden nag; expected revision keeps repeated taps/stale screens safe.
import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  if (typeof body.task_id !== 'string' || !['set', 'update', 'resume'].includes(String(body.waiting_action)) ||
      typeof body.expected_revision !== 'number' || !Number.isSafeInteger(body.expected_revision)) {
    throw new FamilyOpsError('INVALID_INPUT', 'task_id, waiting_action and expected_revision are required', 400);
  }
  if (body.waiting_action !== 'resume' && typeof body.next_check_at !== 'string') {
    throw new FamilyOpsError('INVALID_INPUT', 'next_check_at is required while waiting', 400);
  }
  return jsonResponse(await callServerTx(createServiceRoleClient(), 'server_tx_set_task_waiting', {
    p_actor_id: actorId, p_operation_id: operationId, p_task_id: body.task_id,
    p_waiting_action: body.waiting_action,
    p_waiting_note: typeof body.waiting_note === 'string' ? body.waiting_note : null,
    p_next_check_at: body.waiting_action === 'resume' ? null : body.next_check_at,
    p_expected_revision: body.expected_revision,
  }));
}));

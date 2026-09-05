import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { jsonResponse, withUserMutationHandler } from '../_shared/handler.ts';
import { readJsonBody, requireOperationId } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  const intakeId = body['intake_id'];
  const revision = body['expected_revision'];
  const items = body['selected_items'];
  if (typeof intakeId !== 'string' || !Number.isInteger(revision) || !Array.isArray(items)) {
    throw new FamilyOpsError('INVALID_INPUT','intake_id, expected_revision and selected_items are required',400);
  }
  const client = createServiceRoleClient();
  const { data, error } = await client.rpc('server_tx_confirm_nursery_review',{p_actor_id:actorId,p_operation_id:operationId,p_intake_id:intakeId,p_expected_revision:revision,p_selected_items:items});
  if (error) throw error;
  return jsonResponse(data);
}));

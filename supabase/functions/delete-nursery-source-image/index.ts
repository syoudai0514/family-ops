import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { jsonResponse, withUserMutationHandler } from '../_shared/handler.ts';
import { readJsonBody } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const intakeId = body['intake_id'];
  const revision = body['expected_revision'];
  if (typeof intakeId !== 'string' || !Number.isInteger(revision)) throw new FamilyOpsError('INVALID_INPUT','intake_id and expected_revision are required',400);
  const client = createServiceRoleClient();
  const { data: authz, error: authzError } = await client.rpc('server_tx_authorize_nursery_raw_delete',{p_actor_id:actorId,p_intake_id:intakeId,p_expected_revision:revision});
  if (authzError) throw authzError;
  if (!authz?.authorized) throw new FamilyOpsError('CONFLICT','source image delete not authorized',409);
  if (!authz.already_absent && typeof authz.storage_object_key === 'string') {
    const { error: removeError } = await client.storage.from('nursery-source').remove([authz.storage_object_key]);
    if (removeError) throw removeError;
  }
  const { data, error } = await client.rpc('server_tx_mark_nursery_raw_deleted',{p_actor_id:actorId,p_intake_id:intakeId,p_expected_revision:revision});
  if (error) throw error;
  return jsonResponse(data);
}));

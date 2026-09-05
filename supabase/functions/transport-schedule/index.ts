// Issue #48 final UX contract: one authenticated surface for the transport
// weekly-template timeline and its date-scoped occurrence overrides.
import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { jsonResponse, withUserMutationHandler } from '../_shared/handler.ts';
import { readJsonBody, requireOperationId } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const action = body['action'];
  const client = createServiceRoleClient();

  if (action === 'read') {
    const { data, error } = await client.rpc('server_read_transport_templates', {
      p_actor_id: actorId,
    });
    if (error) throw error;
    return jsonResponse(data ?? { templates: [], overrides: [] });
  }

  const operationId = requireOperationId(body);
  if (action === 'save_template') {
    if (typeof body['valid_from'] !== 'string' || !Array.isArray(body['days'])) {
      throw new FamilyOpsError('INVALID_INPUT', 'valid_from and seven days are required', 400);
    }
    const { data, error } = await client.rpc('server_tx_save_transport_template', {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_valid_from: body['valid_from'],
      p_days: body['days'],
    });
    if (error) throw error;
    return jsonResponse(data);
  }

  if (action === 'set_override') {
    if (typeof body['occurrence_date'] !== 'string') {
      throw new FamilyOpsError('INVALID_INPUT', 'occurrence_date is required', 400);
    }
    const { data, error } = await client.rpc('server_tx_set_transport_occurrence_override', {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_occurrence_date: body['occurrence_date'],
      p_dropoff_overridden: body['dropoff_overridden'] === true,
      p_dropoff_user_id: typeof body['dropoff_user_id'] === 'string' && body['dropoff_user_id']
        ? body['dropoff_user_id']
        : null,
      p_pickup_overridden: body['pickup_overridden'] === true,
      p_pickup_user_id: typeof body['pickup_user_id'] === 'string' && body['pickup_user_id']
        ? body['pickup_user_id']
        : null,
      p_note: typeof body['note'] === 'string' ? body['note'] : null,
    });
    if (error) throw error;
    return jsonResponse(data);
  }

  if (action === 'delete_override') {
    if (typeof body['occurrence_date'] !== 'string') {
      throw new FamilyOpsError('INVALID_INPUT', 'occurrence_date is required', 400);
    }
    const { data, error } = await client.rpc('server_tx_delete_transport_occurrence_override', {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_occurrence_date: body['occurrence_date'],
    });
    if (error) throw error;
    return jsonResponse(data);
  }

  throw new FamilyOpsError('INVALID_INPUT', 'unknown transport schedule action', 400);
}));

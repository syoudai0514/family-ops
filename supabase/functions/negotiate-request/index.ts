// Request negotiation adapter.  It never changes an assignment until the
// canonical attempt command observes confirmations from both parties.
import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

const ACTIONS = ['checking', 'consult', 'edit_terms', 'confirm_terms', 'decline'];

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  if (typeof body.request_id !== 'string' || typeof body.attempt_id !== 'string' || !ACTIONS.includes(String(body.action))) {
    throw new FamilyOpsError('INVALID_INPUT', 'request_id, attempt_id and action are required', 400);
  }
  if (body.terms !== undefined && (typeof body.terms !== 'object' || body.terms === null || Array.isArray(body.terms))) {
    throw new FamilyOpsError('INVALID_INPUT', 'terms must be an object', 400);
  }
  if ((body.expected_revision !== undefined && typeof body.expected_revision !== 'number')
    || (body.expected_terms_revision !== undefined && typeof body.expected_terms_revision !== 'number')) {
    throw new FamilyOpsError('INVALID_INPUT', 'expected revisions must be numbers', 400);
  }
  return jsonResponse(await callServerTx(createServiceRoleClient(), 'server_tx_negotiate_request_v1', {
    p_actor_id: actorId, p_operation_id: operationId, p_request_id: body.request_id,
    p_attempt_id: body.attempt_id, p_action: body.action, p_terms: body.terms ?? null,
    p_expected_revision: body.expected_revision ?? null,
    p_expected_terms_revision: body.expected_terms_revision ?? null,
  }));
}));

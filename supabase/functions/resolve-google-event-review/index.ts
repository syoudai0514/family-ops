import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { jsonResponse, withUserMutationHandler } from '../_shared/handler.ts';

type Body = {
  operationId?: string;
  candidateId?: string;
  candidateKind?: 'protected_change' | 'google_deleted' | 'possible_duplicate' | 'preparation_change';
  expectedRevision?: number;
  resolution?: 'accept_google' | 'keep_family' | 'same_event' | 'different_event' | 'cancel_family' | 'waiting_reschedule' | 'google_only_hidden' | 'apply' | 'keep';
};

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await req.json() as Body;
  if (!body.operationId || !body.candidateId || !Number.isInteger(body.expectedRevision) || !body.resolution) {
    throw new Error('INVALID_INPUT');
  }
  const client = createServiceRoleClient();
  const rpc = body.candidateKind === 'preparation_change'
    ? 'server_tx_resolve_event_preparation_change'
    : 'server_tx_resolve_google_event_review';
  const { data, error } = await client.rpc(rpc, {
    p_actor_id: actorId,
    p_operation_id: body.operationId,
    p_candidate_id: body.candidateId,
    p_expected_revision: body.expectedRevision,
    p_resolution: body.resolution,
  });
  if (error) throw error;
  return jsonResponse(data);
}));

import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { jsonResponse, withUserMutationHandler } from '../_shared/handler.ts';

type Body = {
  operationId?: string;
  candidateId?: string;
  expectedRevision?: number;
  resolution?: 'accept_google' | 'keep_family' | 'same_event' | 'different_event';
};

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await req.json() as Body;
  if (!body.operationId || !body.candidateId || !Number.isInteger(body.expectedRevision) || !body.resolution) {
    throw new Error('INVALID_INPUT');
  }
  const client = createServiceRoleClient();
  const { data, error } = await client.rpc('server_tx_resolve_google_event_review', {
    p_actor_id: actorId,
    p_operation_id: body.operationId,
    p_candidate_id: body.candidateId,
    p_expected_revision: body.expectedRevision,
    p_resolution: body.resolution,
  });
  if (error) throw error;
  return jsonResponse(data);
}));

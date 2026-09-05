import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { jsonResponse, withUserMutationHandler } from '../_shared/handler.ts';
import { readJsonBody } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

const ALLOWED_FIELDS = new Set(['nursery', 'child', 'class', 'date', 'document_group']);

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const intakeId = body['intake_id'];
  const revision = body['expected_revision'];
  const contextId = body['child_school_context_id'];
  const resolvedFields = body['resolved_fields'];
  if (
    typeof intakeId !== 'string' || !Number.isInteger(revision) ||
    (contextId !== null && contextId !== undefined && typeof contextId !== 'string') ||
    !Array.isArray(resolvedFields) || !resolvedFields.every((field) => typeof field === 'string' && ALLOWED_FIELDS.has(field))
  ) {
    throw new FamilyOpsError('INVALID_INPUT', 'intake_id, expected_revision and resolved_fields are required', 400);
  }
  const client = createServiceRoleClient();
  const { data, error } = await client.rpc('server_tx_resolve_nursery_ambiguity', {
    p_actor_id: actorId,
    p_intake_id: intakeId,
    p_expected_revision: revision,
    p_child_school_context_id: contextId ?? null,
    p_resolved_fields: resolvedFields,
  });
  if (error) throw error;
  return jsonResponse(data);
}));

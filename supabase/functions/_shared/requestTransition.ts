import { FamilyOpsError } from './errors.ts';

// Both JWT Edge and authenticated LINE inbox supply the same observed snapshot.
// Never fetch a newer revision to make an old user action succeed.
export function requestTransitionArgs(actorId: string, operationId: string,
  body: Record<string, unknown>, source: 'pwa' | 'line') {
  const actions = ['accept', 'decline', 'checking', 'consult', 'edit_terms', 'confirm_terms', 'cancel'];
  if (typeof body.request_id !== 'string' || typeof body.attempt_id !== 'string'
    || !Number.isSafeInteger(body.expected_revision) || Number(body.expected_revision) < 1
    || !Number.isSafeInteger(body.expected_terms_revision) || Number(body.expected_terms_revision) < 1
    || !actions.includes(String(body.action))) {
    throw new FamilyOpsError('REQUEST_ATTEMPT_STALE', '最新のお願いを開いて、内容を確認してください。', 409);
  }
  return { p_actor_id: actorId, p_operation_id: operationId, p_request_id: body.request_id,
    p_attempt_id: body.attempt_id, p_action: body.action, p_terms: body.terms ?? null,
    p_expected_revision: body.expected_revision, p_expected_terms_revision: body.expected_terms_revision,
    p_source: source };
}

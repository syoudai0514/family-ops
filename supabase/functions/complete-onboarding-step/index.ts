import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { FamilyOpsError } from '../_shared/errors.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';

const STEPS = ['morning_preparation', 'connections', 'notifications', 'week_preview'] as const;

Deno.serve(
  withUserMutationHandler(async (req: Request) => {
    const actorId = await requireUserActor(req);
    const body = await readJsonBody(req);
    // Share the existing setup endpoint: production is at its 100-function limit.
    // Requests without an action retain the original onboarding-step contract.
    if (body.action !== undefined) {
      const client = createServiceRoleClient();
      if (body.action === 'assignment_preview') {
        if (typeof body.request_id !== 'string' || typeof body.attempt_id !== 'string') {
          throw new FamilyOpsError('INVALID_INPUT', 'お願いを確認してください', 400);
        }
        return jsonResponse(await callServerTx(client, 'server_read_assignment_preview', {
          p_actor_id: actorId,
          p_request_id: body.request_id,
          p_attempt_id: body.attempt_id,
        }));
      }
      if (body.action === 'read') {
        return jsonResponse(await callServerTx(client, 'server_read_family_setup', {
          p_actor_id: actorId,
        }));
      }
      if (!['save_context', 'finish_later', 'reissue_invite'].includes(String(body.action))) {
        throw new FamilyOpsError('INVALID_INPUT', '操作を確認してください', 400);
      }
      return jsonResponse(await callServerTx(client, 'server_tx_family_setup', {
        p_actor_id: actorId,
        p_operation_id: requireOperationId(body),
        p_action: body.action,
        p_payload: body.payload ?? {},
      }));
    }
    const operationId = requireOperationId(body);
    const step = body.step;
    if (typeof step !== 'string' || !STEPS.includes(step as (typeof STEPS)[number])) {
      throw new FamilyOpsError('INVALID_INPUT', 'unknown onboarding step', 400);
    }
    const result = await callServerTx<{ household_id: string; step: string; completed: true }>(
      createServiceRoleClient(),
      'server_tx_complete_onboarding_step',
      { p_actor_id: actorId, p_operation_id: operationId, p_step: step },
    );
    return jsonResponse(result);
  }),
);

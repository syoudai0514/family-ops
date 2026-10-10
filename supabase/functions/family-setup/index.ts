import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { FamilyOpsError } from '../_shared/errors.ts';
import { jsonResponse, withUserMutationHandler } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';

Deno.serve(
  withUserMutationHandler(async (req: Request) => {
    const actorId = await requireUserActor(req);
    const body = await readJsonBody(req);
    const client = createServiceRoleClient();
    if (body.action === 'assignment_preview') {
      if (typeof body.request_id !== 'string' || typeof body.attempt_id !== 'string')
        throw new FamilyOpsError('INVALID_INPUT', 'お願いを確認してください', 400);
      return jsonResponse(
        await callServerTx(client, 'server_read_assignment_preview', {
          p_actor_id: actorId,
          p_request_id: body.request_id,
          p_attempt_id: body.attempt_id,
        }),
      );
    }
    if (body.action === 'read')
      return jsonResponse(
        await callServerTx(client, 'server_read_family_setup', { p_actor_id: actorId }),
      );
    if (!['save_context', 'finish_later', 'reissue_invite'].includes(String(body.action))) {
      throw new FamilyOpsError('INVALID_INPUT', '操作を確認してください', 400);
    }
    return jsonResponse(
      await callServerTx(client, 'server_tx_family_setup', {
        p_actor_id: actorId,
        p_operation_id: requireOperationId(body),
        p_action: body.action,
        p_payload: body.payload ?? {},
      }),
    );
  }),
);

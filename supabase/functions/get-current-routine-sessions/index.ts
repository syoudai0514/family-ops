// verify_jwt=true. Read-only current-input discovery for Today; session
// mutations still use their existing, actor-checked canonical commands.
import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx } from '../_shared/rpc.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  return jsonResponse(await callServerTx(
    createServiceRoleClient(),
    'server_read_current_routine_sessions',
    { p_actor_id: actorId },
  ));
}));

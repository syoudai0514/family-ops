import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { FamilyOpsError } from '../_shared/errors.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';
Deno.serve(withUserMutationHandler(async(req)=>{const b=await readJsonBody(req);if(typeof b.user_id!=='string'||(b.family_role!=='papa'&&b.family_role!=='mama'))throw new FamilyOpsError('INVALID_INPUT','user_id and family_role are required',400);return jsonResponse(await callServerTx(createServiceRoleClient(),'server_tx_set_family_role',{p_actor_id:await requireUserActor(req),p_operation_id:requireOperationId(b),p_user_id:b.user_id,p_family_role:b.family_role}));}));

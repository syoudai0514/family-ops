import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';
Deno.serve(withUserMutationHandler(async(req)=>{const actorId=await requireUserActor(req);const body=await readJsonBody(req);if(typeof body.start_date!=='string'||typeof body.end_date!=='string')throw new FamilyOpsError('INVALID_INPUT','start_date and end_date are required',400);return jsonResponse(await callServerTx(createServiceRoleClient(),'server_tx_get_week_schedule',{p_actor_id:actorId,p_start_date:body.start_date,p_end_date:body.end_date}));}));

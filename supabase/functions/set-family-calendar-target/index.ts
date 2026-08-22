import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { FamilyOpsError } from '../_shared/errors.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';
Deno.serve(withUserMutationHandler(async (req) => { const body=await readJsonBody(req); const id=body.calendar_connection_id; if(typeof id!=='string') throw new FamilyOpsError('INVALID_INPUT','calendar_connection_id is required',400); return jsonResponse(await callServerTx(createServiceRoleClient(),'server_tx_set_family_calendar_target',{p_actor_id:await requireUserActor(req),p_operation_id:requireOperationId(body),p_calendar_connection_id:id})); }));

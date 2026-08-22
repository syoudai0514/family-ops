import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { withUserMutationHandler, jsonResponse } from '../_shared/handler.ts';
import { callServerTx, readJsonBody, requireOperationId } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';
Deno.serve(withUserMutationHandler(async (req) => { const actorId=await requireUserActor(req); const body=await readJsonBody(req); const operationId=requireOperationId(body); if(typeof body.task_definition_id!=='string'||!Number.isInteger(body.weekday)) throw new FamilyOpsError('INVALID_INPUT','task_definition_id and weekday are required',400); return jsonResponse(await callServerTx(createServiceRoleClient(),'server_tx_deactivate_recurrence',{p_actor_id:actorId,p_operation_id:operationId,p_task_definition_id:body.task_definition_id,p_weekday:body.weekday,p_slot_key:typeof body.slot_key==='string'?body.slot_key:null})); }));

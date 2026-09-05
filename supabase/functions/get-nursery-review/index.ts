import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { jsonResponse, withUserMutationHandler } from '../_shared/handler.ts';
import { readJsonBody } from '../_shared/rpc.ts';
import { FamilyOpsError } from '../_shared/errors.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const intakeId = body['intake_id'];
  if (typeof intakeId !== 'string') throw new FamilyOpsError('INVALID_INPUT','intake_id is required',400);
  const client = createServiceRoleClient();
  const { data, error } = await client.rpc('server_read_nursery_review',{p_actor_id:actorId,p_intake_id:intakeId});
  if (error) throw error;
  let sourceImageUrl: string|null = null;
  if (data?.raw_available) {
    const { data: locator, error: locatorError } = await client.rpc('server_read_nursery_source_locator',{p_actor_id:actorId,p_intake_id:intakeId});
    if (locatorError) throw locatorError;
    if (locator?.available && typeof locator.storage_object_key === 'string') {
      const { data: signed, error: signedError } = await client.storage.from('nursery-source').createSignedUrl(locator.storage_object_key,300);
      if (signedError) throw signedError;
      sourceImageUrl = signed.signedUrl;
    }
  }
  return jsonResponse({...data,source_image_url:sourceImageUrl});
}));

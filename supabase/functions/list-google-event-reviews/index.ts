import { createServiceRoleClient, requireUserActor } from '../_shared/auth.ts';
import { jsonResponse, withUserMutationHandler } from '../_shared/handler.ts';

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const client = createServiceRoleClient();
  const { data, error } = await client.rpc('server_read_google_event_reviews_v2', { p_actor_id: actorId });
  if (error) throw error;
  return jsonResponse(data ?? []);
}));

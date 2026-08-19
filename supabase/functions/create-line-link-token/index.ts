// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/06_LINE_INTEGRATION.md #2 "account linking": issues a
// single-use, 10-minute link token whose SHA-256 hash is stored server-side
// (public.server_tx_create_line_link_token) — the raw token is returned to
// the caller exactly once and never persisted. The user pastes/sends this
// token as a LINE text message to the Family Ops LINE official account;
// process-line-inbox (supabase/functions/process-line-inbox) recognizes it
// in an inbound message and calls server_tx_claim_line_link_token with the
// LINE-verified source.userId to complete the link. This endpoint never
// talks to the LINE API itself.
//
// LINE_OA_BASIC_ID (optional secret, referenced by name only — see
// MANUAL_SETUP_REQUIRED.md): when configured, the response also includes a
// `line_add_friend_url` deep link (LINE's documented
// https://line.me/R/oaMessage/{basic_id}/?{text} URL scheme) that opens a
// chat with the OA and pre-fills the raw token as the message to send. Not
// required for correctness — raw_token is always returned and can be
// pasted into the chat manually.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";

interface CreateLineLinkTokenResult {
  token_id: string;
  household_id: string;
  raw_token: string;
  expires_at: string;
}

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<CreateLineLinkTokenResult>(
    serviceClient,
    "server_tx_create_line_link_token",
    { p_actor_id: actorId, p_operation_id: operationId },
  );

  const basicId = Deno.env.get("LINE_OA_BASIC_ID");
  const responseBody: Record<string, unknown> = { ...result };
  if (basicId) {
    responseBody.line_add_friend_url =
      `https://line.me/R/oaMessage/${encodeURIComponent(basicId)}/?${encodeURIComponent(result.raw_token)}`;
  }

  return jsonResponse(responseBody);
}));

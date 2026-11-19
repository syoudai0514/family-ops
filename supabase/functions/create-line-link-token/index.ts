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
import { FamilyOpsError } from "../_shared/errors.ts";

interface CreateLineLinkTokenResult {
  token_id: string;
  household_id: string;
  raw_token: string;
  expires_at: string;
}

// The OA's Basic ID (@xxxx). LINE_OA_BASIC_ID wins when set; otherwise it is read once from
// LINE (GET /v2/bot/info) with the channel token every LINE function already has. Without it the
// screen could only show a 64-character code to copy into a chat the person had to find first.
let cachedBasicId: string | null = null;
export async function resolveBasicId(fetchImpl: typeof fetch = fetch): Promise<string | null> {
  const configured = Deno.env.get("LINE_OA_BASIC_ID")?.trim();
  if (configured) return configured;
  if (cachedBasicId) return cachedBasicId;
  const token = Deno.env.get("LINE_CHANNEL_ACCESS_TOKEN")?.trim();
  if (!token) return null;
  try {
    const response = await fetchImpl("https://api.line.me/v2/bot/info", {
      headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(3000),
    });
    if (!response.ok) return null;
    const info = await response.json() as { basicId?: unknown };
    cachedBasicId = typeof info.basicId === "string" && info.basicId.startsWith("@") ? info.basicId : null;
    return cachedBasicId;
  } catch {
    return null; // The code still works when typed by hand.
  }
}

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const serviceClient = createServiceRoleClient();
  // member_user_id: a 7-day code for the other adult, to send to them (the seat's LINE changes hands).
  const memberUserId = body["member_user_id"];
  if (memberUserId !== undefined && (typeof memberUserId !== "string" || memberUserId.length === 0)) {
    throw new FamilyOpsError("INVALID_INPUT", "member_user_id must be a string", 400);
  }
  const result = memberUserId
    ? await callServerTx<CreateLineLinkTokenResult>(
      serviceClient,
      "server_tx_create_member_line_link_token",
      { p_actor_id: actorId, p_operation_id: operationId, p_member_user_id: memberUserId },
    )
    : await callServerTx<CreateLineLinkTokenResult>(
      serviceClient,
      "server_tx_create_line_link_token",
      { p_actor_id: actorId, p_operation_id: operationId },
    );

  const basicId = await resolveBasicId();
  const responseBody: Record<string, unknown> = { ...result };
  if (basicId) {
    // Opens the おうちノート chat with the code already typed: the person only presses 送信.
    responseBody.line_add_friend_url =
      `https://line.me/R/oaMessage/${encodeURIComponent(basicId)}/?${encodeURIComponent(result.raw_token)}`;
    // Adds おうちノート as a friend, so the daily messages can reach this person afterwards.
    responseBody.line_follow_url = `https://line.me/R/ti/p/${encodeURIComponent(basicId)}`;
  }

  return jsonResponse(responseBody);
}));

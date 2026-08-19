// verify_jwt=false — external provider class (see supabase/config.toml +
// EDGE_FUNCTION_AUTH_MATRIX.md). verify_jwt=false does NOT mean "trusted":
// the raw-body LINE signature is verified before any parsing or DB access.
// docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md #6 "line-webhook-receiver";
// 04_SECURITY_RLS_PRIVACY.md #11.
//
// Full message/postback business processing (natural-language parsing,
// pending-action creation, routine completion) is WP6 scope
// (process-line-inbox). This function's job is narrow and safety-critical:
// verify the signature, durably dedup the event, return fast.
import { createServiceRoleClient, verifyLineSignature } from "../_shared/auth.ts";
import { withServiceHandler } from "../_shared/handler.ts";

interface LineWebhookEvent {
  type: string;
  webhookEventId?: string;
  source?: { userId?: string };
  [key: string]: unknown;
}

Deno.serve(withServiceHandler(async (req: Request) => {
  const rawBody = await req.text();
  const signature = req.headers.get("X-Line-Signature");

  const valid = await verifyLineSignature(rawBody, signature);
  if (!valid) {
    // Invalid signature: reject before parsing the body or touching the DB.
    return new Response("invalid signature", { status: 401 });
  }

  let events: LineWebhookEvent[] = [];
  try {
    const parsed = JSON.parse(rawBody) as { events?: LineWebhookEvent[] };
    events = parsed.events ?? [];
  } catch {
    // LINE expects 200 even for payloads we can't use, to avoid redelivery storms.
    return new Response("ok", { status: 200 });
  }

  const serviceClient = createServiceRoleClient();

  for (const event of events) {
    const providerEventId = event.webhookEventId;
    if (!providerEventId) continue; // cannot dedup without an id; skip safely

    // Durable inbox insert; UNIQUE(provider, provider_event_id) makes
    // redelivery a no-op. Actor identity is never taken from event.source
    // here — process-line-inbox (WP6) resolves it via
    // private.line_user_links from the verified source.userId only.
    await serviceClient.from("webhook_inbox").insert({
      provider: "line",
      provider_event_id: providerEventId,
      source_external_user_id: event.source?.userId ?? null,
      payload: event,
    }).select().maybeSingle();
    // Ignore unique-violation errors from redelivery — dedup is the point.
  }

  return new Response("ok", { status: 200 });
}));

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
//
// v6 review fixes:
// - P1-2: never touch private.webhook_inbox via the Data API `.from()`
//   client — go through public.server_tx_ingest_line_webhook_event (the
//   only Edge-to-DB interface for private-schema state; see
//   docs/design/v6/15_DDL_CONTRACT.md #8).
// - P1-3: 200 is returned only for a signature-valid, successfully-durable
//   (new-or-duplicate) event. A genuine DB failure while persisting a new
//   event propagates as 5xx so LINE's own delivery retries it — silently
//   swallowing that failure and returning 200 would drop the event forever.
import 'jsr:@supabase/functions-js@2/edge-runtime.d.ts';
import { createServiceRoleClient, verifyLineSignature } from '../_shared/auth.ts';
import { withServiceHandler } from '../_shared/handler.ts';
import { kickLineWorkers } from './lineWorkerKick.ts';

interface LineWebhookEvent {
  type: string;
  webhookEventId?: string;
  source?: { userId?: string };
  [key: string]: unknown;
}

Deno.serve(
  withServiceHandler(async (req: Request) => {
    const rawBody = await req.text();
    const signature = req.headers.get('X-Line-Signature');

    const valid = await verifyLineSignature(rawBody, signature);
    if (!valid) {
      // Invalid signature: reject before parsing the body or touching the DB.
      return new Response('invalid signature', { status: 401 });
    }

    let events: LineWebhookEvent[] = [];
    try {
      const parsed = JSON.parse(rawBody) as { events?: LineWebhookEvent[] };
      events = parsed.events ?? [];
    } catch {
      // Not a DB failure — there is nothing to persist. LINE expects 200 even
      // for payloads we can't use, to avoid pointless redelivery storms for a
      // request that will never parse differently on retry.
      return new Response('ok', { status: 200 });
    }

    const serviceClient = createServiceRoleClient();

    for (const event of events) {
      const providerEventId = event.webhookEventId;
      if (!providerEventId) continue; // cannot dedup without an id; skip safely

      // UNIQUE(provider, provider_event_id) inside the RPC makes redelivery of
      // an already-durable event a no-op (is_new=false). Actor identity is
      // never taken from event.source here — process-line-inbox (WP6) resolves
      // it via private.line_user_links from the verified source.userId only.
      const { error } = await serviceClient.rpc('server_tx_ingest_line_webhook_event', {
        p_provider_event_id: providerEventId,
        p_source_external_user_id: event.source?.userId ?? null,
        p_payload: event,
      });

      if (error) {
        // Genuine persistence failure (not a duplicate — that path never
        // errors). Abort and let the caller (LINE) retry the whole delivery;
        // already-durable events in this same payload are safely no-ops next
        // time thanks to the provider_event_id UNIQUE constraint.
        console.error('line-webhook-receiver: failed to persist webhook event', {
          providerEventId,
          message: error.message,
        });
        return new Response('internal error', { status: 500 });
      }
    }

    // The durable insert above is the acknowledgement boundary.  Do not await
    // parsing, Gemini, or delivery here: LINE receives 200 immediately, while
    // the background chain normally returns the sender preview in seconds.
    // Any failed kick is harmless because the existing one-minute cron retains
    // its lease/retry/dead-letter role as the recovery path.
    EdgeRuntime.waitUntil(
      kickLineWorkers(
        Deno.env.get('SUPABASE_URL') ?? '',
        Deno.env.get('CRON_WORKER_TOKEN') ?? '',
      ).then((result) => {
        if (!result.ok)
          console.warn('line-webhook-receiver: immediate worker kick deferred to cron', {
            worker: result.failedWorker,
          });
      }),
    );

    return new Response('ok', { status: 200 });
  }),
);

// verify_jwt=false — external provider class. The raw-body LINE signature is
// verified before parsing or DB access. The receiver only durably enqueues;
// business parsing and nursery-image extraction happen in workers.
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };

import { createServiceRoleClient, verifyLineSignature } from '../_shared/auth.ts';
import { withServiceHandler } from '../_shared/handler.ts';
import { kickLineWorkers } from './lineWorkerKick.ts';

interface LineWebhookEvent {
  type: string;
  webhookEventId?: string;
  timestamp?: number;
  source?: { userId?: string };
  message?: { id?: string; type?: string };
  [key: string]: unknown;
}

async function kickNurseryWorker(baseUrl: string, workerToken: string): Promise<void> {
  if (!baseUrl || !workerToken) return;
  try {
    const response = await fetch(`${baseUrl}/functions/v1/process-nursery-image-intake`, {
      method: 'POST',
      headers: { 'X-Family-Ops-Worker-Token': workerToken, 'Content-Type': 'application/json' },
      body: '{}',
    });
    if (!response.ok) console.warn('line-webhook-receiver: nursery worker kick deferred', { status: response.status });
  } catch (error) {
    console.warn('line-webhook-receiver: nursery worker kick failed', { message: error instanceof Error ? error.message : String(error) });
  }
}

Deno.serve(
  withServiceHandler(async (req: Request) => {
    const rawBody = await req.text();
    const signature = req.headers.get('X-Line-Signature');
    const valid = await verifyLineSignature(rawBody, signature);
    if (!valid) return new Response('invalid signature', { status: 401 });

    let events: LineWebhookEvent[] = [];
    try {
      const parsed = JSON.parse(rawBody) as { events?: LineWebhookEvent[] };
      events = parsed.events ?? [];
    } catch {
      return new Response('ok', { status: 200 });
    }

    const serviceClient = createServiceRoleClient();
    let nurseryImageQueued = false;

    for (const event of events) {
      const providerEventId = event.webhookEventId;
      if (!providerEventId) continue;
      const { error } = await serviceClient.rpc('server_tx_ingest_line_webhook_event', {
        p_provider_event_id: providerEventId,
        p_source_external_user_id: event.source?.userId ?? null,
        p_payload: event,
      });
      if (error) {
        console.error('line-webhook-receiver: failed to persist webhook event', { providerEventId, message: error.message });
        return new Response('internal error', { status: 500 });
      }

      // Q89: after signature validation, a LINE image gets a separate durable,
      // idempotent nursery-intake row. No image bytes are downloaded and no AI
      // or canonical mutation runs inside the webhook acknowledgement path.
      if (event.type === 'message' && event.message?.type === 'image' && event.message.id && event.source?.userId) {
        const receivedAt = typeof event.timestamp === 'number' ? new Date(event.timestamp).toISOString() : new Date().toISOString();
        const { error: nurseryError } = await serviceClient.rpc('server_tx_enqueue_nursery_line_image', {
          p_provider_event_id: providerEventId,
          p_line_message_id: event.message.id,
          p_line_user_id: event.source.userId,
          p_received_at: receivedAt,
        });
        if (nurseryError) {
          console.error('line-webhook-receiver: failed to persist nursery image intake', { providerEventId, message: nurseryError.message });
          return new Response('internal error', { status: 500 });
        }
        nurseryImageQueued = true;
      }
    }

    const baseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const workerToken = Deno.env.get('CRON_WORKER_TOKEN') ?? '';
    EdgeRuntime.waitUntil(
      Promise.all([
        kickLineWorkers(baseUrl, workerToken).then((result) => {
          if (!result.ok) console.warn('line-webhook-receiver: immediate worker kick deferred to cron', { worker: result.failedWorker });
        }),
        nurseryImageQueued ? kickNurseryWorker(baseUrl, workerToken) : Promise.resolve(),
      ]).then(() => undefined),
    );
    return new Response('ok', { status: 200 });
  }),
);

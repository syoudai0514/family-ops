import { assertEquals } from 'jsr:@std/assert@1';
import { kickLineWorkers } from './lineWorkerKick.ts';

Deno.test('immediate kick drains inbox, pending actions, then delivery', async () => {
  const calls: string[] = [];
  const result = await kickLineWorkers(
    'https://example.supabase.co/',
    'worker-token',
    async (url) => {
      calls.push(String(url));
      return new Response(null, { status: 200 });
    },
  );
  assertEquals(result, { ok: true, failedWorker: null });
  assertEquals(calls, [
    'https://example.supabase.co/functions/v1/process-line-inbox',
    'https://example.supabase.co/functions/v1/process-pending-actions',
    'https://example.supabase.co/functions/v1/send-notifications',
  ]);
});

Deno.test('a failed immediate kick leaves durable work for cron recovery', async () => {
  const result = await kickLineWorkers(
    'https://example.supabase.co',
    'worker-token',
    async () => new Response(null, { status: 503 }),
  );
  assertEquals(result, { ok: false, failedWorker: 'process-line-inbox' });
});

import { assertEquals } from 'jsr:@std/assert@1';
import { findRequestReceivedItem, isRequestReceivedType } from './requestNotificationPayload.ts';

Deno.test('canonical request.received is recognized at LINE worker boundary', () => {
  assertEquals(isRequestReceivedType('request.received'), true);
  assertEquals(isRequestReceivedType('request_received'), true);
  assertEquals(isRequestReceivedType('request.sent'), false);
});

Deno.test('canonical assignment request payload remains actionable after outbox bridge', () => {
  const item = findRequestReceivedItem([
    {
      type: 'request.received',
      title: '担当変更のお願い',
      body: 'お迎えをお願いしてもいい？',
      payload: {
        request_id: 'req-1',
        attempt_id: 'attempt-1',
        revision: 1,
        terms_revision: 1,
        request_kind: 'assignment_change',
        scope: 'once' as const,
      },
    },
  ]);

  assertEquals(item?.payload?.request_id, 'req-1');
  assertEquals(item?.payload?.request_kind, 'assignment_change');
});

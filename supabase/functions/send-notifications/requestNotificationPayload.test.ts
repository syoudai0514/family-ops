import { assertEquals } from 'jsr:@std/assert@1';
import { findRequestReceivedItem, isRequestReceivedType, requestOutcomeText } from './requestNotificationPayload.ts';

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


Deno.test('request outcome notifications state the actual result', () => {
  assertEquals(
    requestOutcomeText({ type: 'request.declined', title: 'お願いを更新しました', body: 'お迎え' }),
    'お願いは「難しい」と返されました。\nお迎え\nお願いは成立していません。',
  );
  assertEquals(
    requestOutcomeText({ type: 'request.accepted', title: 'お願いを更新しました', body: 'お迎え' }),
    'お願いが引き受けられました。\nお迎え',
  );
  assertEquals(
    requestOutcomeText({ type: 'request.checking', title: '確認中です', body: 'お迎え' }),
    '相手が確認中です。\nお迎え\nまだ成立していません。',
  );
});

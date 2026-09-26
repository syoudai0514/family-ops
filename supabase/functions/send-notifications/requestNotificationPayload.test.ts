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
    requestOutcomeText({
      type: 'request.accepted',
      title: 'お願いを更新しました',
      body: 'お迎え',
      payload: {
        request_kind: 'assignment_change',
        scope: 'once',
        due_at: '2026-09-14T09:20:00.000Z',
        recipient_label: 'ママ',
      },
    }),
    '✓ ママが引き受けました\n9/14 18:20 お迎え\n今回だけ\n担当変更は確定しています。',
  );
  assertEquals(
    requestOutcomeText({ type: 'request.checking', title: '確認中です', body: 'お迎え' }),
    '相手が確認中です。\nお迎え\nまだ成立していません。',
  );
  assertEquals(
    requestOutcomeText({ type: 'request.checking', title: '引き受ける意向あり', body: '相手が「引き受ける」を押しました。最終確認待ちです。', payload: { followup: 'recipient_final_confirmation' } }),
    '引き受ける意向あり\n相手が「引き受ける」を押しました。最終確認待ちです。',
  );
  assertEquals(
    requestOutcomeText({ type: 'request.checking', title: '最終確認が残っています', body: '「お迎え」はまだ確定していません。', payload: { reminder: 'final_confirmation' } }),
    '最終確認が残っています\n「お迎え」はまだ確定していません。',
  );
});

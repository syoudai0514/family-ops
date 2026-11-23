import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { buildConsentCarousel, consentOfferText, loadConsentCarousel } from './assignmentConsent.ts';

const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const offer = { offer_id: id, kind: 'rule' as const, snapshot: { title: '準備', strategy: 'dropoff_assignee', phase: 'morning', weekday: 1,
  scheduled_local_time: '07:10:00', effective_from: '2026-11-01', effective_to: null, fallback_assignee_id: null,
  subtasks: [{ title: '体操着', required: true }, { title: '余裕があれば', required: false }] } };

Deno.test('proposal shows exact weekday, role, dates and all subtasks; buttons use its own offer id', () => {
  const lines = consentOfferText(offer)!;
  assertStringIncludes(lines.join('\n'), '月曜 朝 07:10');
  assertStringIncludes(lines.join('\n'), '送りを担当する人');
  assertStringIncludes(lines.join('\n'), '2026-11-01〜終了日なし');
  assertStringIncludes(lines.join('\n'), '・体操着');
  assertStringIncludes(lines.join('\n'), '・余裕があれば（任意）');
  const text = JSON.stringify(buildConsentCarousel([offer]));
  for (const answer of ['agree', 'change', 'later']) assertStringIncludes(text, `offer_id=${id}&answer=${answer}`);
});

Deno.test('transport proposal shows all of the recipient’s weekly legs and times', () => {
  const result = consentOfferText({ offer_id: id, kind: 'transport', snapshot: {
    valid_from: '2026-11-01', valid_to: '2026-12-31', days: [
      { weekday: 1, dropoff: true, pickup: true, dropoff_time: '08:30:00', pickup_time: '17:00:00' },
      { weekday: 3, dropoff: null, pickup: true, dropoff_time: null, pickup_time: null },
    ],
  } });
  assertEquals(result, ['「送り迎え」', '期間：2026-11-01〜2026-12-31', '月曜：送り 08:30 ／ 迎え 17:00', '水曜：迎え 時間未設定']);
});

Deno.test('unrenderable, overlong, or incomplete offers never produce a consent button', () => {
  assertEquals(buildConsentCarousel([{ ...offer, snapshot: { ...offer.snapshot, strategy: 'unknown' } }]), null);
  assertEquals(buildConsentCarousel([{ ...offer, snapshot: { ...offer.snapshot, title: '長'.repeat(121) } }]), null);
  assertEquals(buildConsentCarousel([{ ...offer, snapshot: { ...offer.snapshot, subtasks: Array(9).fill({ title: '準備', required: true }) } }]), null);
  assertEquals(buildConsentCarousel([offer, offer, offer, offer]), null);
  assertEquals(buildConsentCarousel([{ ...offer, offer_id: 'bad' }]), null);
});

Deno.test('only Sunday’s own first morning note can request proposals', async () => {
  const calls: unknown[] = [];
  const client = { rpc: (name: string, args: unknown) => { calls.push({ name, args }); return Promise.resolve({ data: [offer], error: null }); } } as unknown as SupabaseClient;
  const item = { type: 'daily_brief.v2', title: '朝のおうちノート', body: '朝の内容', user_notification_id: id };
  const sunday = new Date('2026-11-29T00:00:00Z');
  assertEquals(await loadConsentCarousel(client, 'actor', { items: [item] }, new Date('2026-11-28T00:00:00Z')), null);
  assertEquals(await loadConsentCarousel(client, 'actor', { items: [{ title: '先の通知' }, item] }, sunday), null);
  assertEquals(await loadConsentCarousel(client, 'actor', { items: [{ ...item, body: '長'.repeat(5000) }] }, sunday), null);
  assertEquals(await loadConsentCarousel(client, 'actor', { items: [item, item] }, sunday), null);
  assertEquals(calls.length, 0);
  assertEquals((await loadConsentCarousel(client, 'actor', { items: [item] }, sunday))?.type, 'flex');
  assertEquals(calls, [{ name: 'server_tx_prepare_weekly_assignment_consent_v1', args: { p_actor_id: 'actor', p_notification_id: id } }]);
});

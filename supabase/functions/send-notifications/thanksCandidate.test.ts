import { assertEquals } from 'jsr:@std/assert@1';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { loadThanksCandidate } from './thanksCandidate.ts';
import { buildBriefQuickReply } from './briefQuickReply.ts';
import { buildBundledText } from './bundledText.ts';

Deno.test('morning thanks button targets the server-selected event and keeps the invitation in the text', async () => {
  let requested: Record<string, unknown> | undefined;
  const client = {
    rpc: (_name: string, args: Record<string, unknown>) => {
      requested = args;
      return Promise.resolve({ data: [{ id: 'event', kind: 'task', title: 'お迎え', recipient_id: 'm' }], error: null });
    },
    from: () => {
      const chain = { select: () => chain, eq: () => chain, maybeSingle: () => Promise.resolve({ data: { family_role: 'mama' }, error: null }) };
      return chain;
    },
  } as unknown as SupabaseClient;
  const candidate = await loadThanksCandidate(client, 'actor', 'household', new Date('2027-01-01T00:00:00+09:00'));
  assertEquals(candidate?.name, 'ママ');
  assertEquals(requested?.p_local_date, '2026-12-31');
  const actions = buildBriefQuickReply('daily_brief.v2', { thanks: candidate });
  assertEquals(actions?.[0], {
    type: 'postback', label: 'ありがとうを送る', data: 'action=send_thanks&kind=task&id=event', displayText: 'ありがとうを送る',
  });
  const result = buildBundledText({ items: [{ title: '朝', body: '朝の予定' }] }, 'daily_brief.v2', undefined, null, 'ママがお迎えを代わってくれました');
  assertEquals(result.text.includes('ママがお迎えを代わってくれました'), true);
});

Deno.test('failure to load a candidate keeps the normal brief usable', async () => {
  const client = { rpc: () => Promise.resolve({ data: null, error: { message: 'unavailable' } }) } as unknown as SupabaseClient;
  assertEquals(await loadThanksCandidate(client, 'actor', 'household'), null);
});

import { assertEquals, assertThrows } from 'jsr:@std/assert@1';
import { validateGooglePatch } from './googleEvent.ts';

Deno.test('Google event patches preserve omitted fields and accept one-occurrence changes', () => {
  assertEquals(validateGooglePatch({ summary: '新しい予定名' }), { summary: '新しい予定名' });
  assertEquals(validateGooglePatch({ start: { date: '2026-11-24' }, end: { date: '2026-11-25' } }), {
    start: { date: '2026-11-24' }, end: { date: '2026-11-25' },
  });
  assertEquals(validateGooglePatch({ start: { dateTime: '2026-11-24T09:00:00+09:00' }, end: { dateTime: '2026-11-24T10:00:00+09:00' } }), {
    start: { dateTime: '2026-11-24T09:00:00+09:00', timeZone: 'Asia/Tokyo' },
    end: { dateTime: '2026-11-24T10:00:00+09:00', timeZone: 'Asia/Tokyo' },
  });
});

Deno.test('Google event patches reject unsupported fields, impossible dates and empty intervals', () => {
  assertThrows(() => validateGooglePatch({ attendees: [] }));
  assertThrows(() => validateGooglePatch({ summary: ' ' }));
  assertThrows(() => validateGooglePatch({ start: { date: '2026-02-30' }, end: { date: '2026-03-03' } }));
  assertThrows(() => validateGooglePatch({ start: { date: '2026-11-24' }, end: { date: '2026-11-24' } }));
  assertThrows(() => validateGooglePatch({ start: { dateTime: '2026-11-24T10:00:00+09:00' }, end: { dateTime: '2026-11-24T09:00:00+09:00' } }));
});

import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { assertRejects } from 'jsr:@std/assert@1';
import { googleEventCommand } from './googleEvent.ts';

Deno.test('Google edit checks the household, ETag, and mirror ownership before patching', async () => {
  let occurrence: Record<string, unknown> | null = { calendar_connection_id: 'connection', google_event_id: 'instance', family_ops_mirror: false };
  let etag = '"v1"';
  let patchCalls = 0;
  let status = 200;
  const client = {
    from(table: string) {
      const chain = {
        select: () => chain,
        eq: () => chain,
        neq: () => chain,
        maybeSingle: () => Promise.resolve({ data: table === 'household_members' ? { household_id: 'household' } : occurrence, error: null }),
      };
      return chain;
    },
    rpc: () => Promise.resolve({ error: null }),
  } as unknown as SupabaseClient;
  const provider = {
    getAccessTokenForConnection: () => Promise.resolve({ accessToken: 'access', externalCalendarId: 'family', householdId: 'household' }),
    getEvent: () => Promise.resolve({ status: 200 as const, body: {}, etag }),
    patchEvent: () => { patchCalls++; return Promise.resolve({ status, body: {} }); },
  };
  const body = { action: 'save_google_event', occurrence_id: 'event', etag: '"v1"', changes: { summary: '予定' } };
  assertEquals(await googleEventCommand(client, 'actor', body, provider), { saved: true, syncRequested: true });
  assertEquals(patchCalls, 1);

  etag = '"v2"';
  await assertRejects(() => googleEventCommand(client, 'actor', body, provider), Error, 'Google側で予定が変更');
  assertEquals(patchCalls, 1);
  etag = '"v1"';
  status = 412;
  await assertRejects(() => googleEventCommand(client, 'actor', body, provider), Error, 'Google側で予定が変更');
  occurrence = { ...occurrence, family_ops_mirror: true };
  await assertRejects(() => googleEventCommand(client, 'actor', body, provider), Error, 'おうちノート側');
  occurrence = null;
  await assertRejects(() => googleEventCommand(client, 'actor', body, provider), Error, '見つかりません');
});

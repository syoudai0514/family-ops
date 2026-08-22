import { assertEquals } from 'jsr:@std/assert@1';
import {
  GOOGLE_CALENDAR_SCOPES,
  GoogleCalendarApiError,
  isGoogleCalendarForbiddenError,
  listEligibleCalendarCandidates,
  revalidateCalendarEligibilityAfterForbidden,
} from './googleCalendar.ts';

Deno.test('keeps every writable Asia/Tokyo calendar as a candidate without choosing a target', () => {
  const candidates = listEligibleCalendarCandidates([
    { id: 'primary', summary: 'Personal', accessRole: 'owner', timeZone: 'Asia/Tokyo' },
    { id: 'shared', summary: 'Shared', accessRole: 'writer', timeZone: 'Asia/Tokyo' },
    { id: 'private-writer', summary: 'Private', accessRole: 'writerWithoutPrivateAccess', timeZone: 'Asia/Tokyo' },
    { id: 'reader', summary: 'Read only', accessRole: 'reader', timeZone: 'Asia/Tokyo' },
    { id: 'freebusy', summary: 'Free busy', accessRole: 'freeBusyReader', timeZone: 'Asia/Tokyo' },
    { id: 'other-zone', summary: 'Other zone', accessRole: 'owner', timeZone: 'America/New_York' },
  ]);

  assertEquals(candidates.map((candidate) => candidate.id), ['primary', 'shared', 'private-writer']);
  assertEquals(candidates.some((candidate) => candidate.accessRole === 'reader'), false);
  assertEquals(candidates.some((candidate) => candidate.timeZone !== 'Asia/Tokyo'), false);
});

Deno.test('uses only the two Calendar OAuth scopes', () => {
  assertEquals(GOOGLE_CALENDAR_SCOPES, [
    'https://www.googleapis.com/auth/calendar.events',
    'https://www.googleapis.com/auth/calendar.calendarlist.readonly',
  ]);
});

Deno.test('treats only an explicit Google Calendar API 403 as permission revalidation input', () => {
  assertEquals(
    isGoogleCalendarForbiddenError(new GoogleCalendarApiError('events.patch', 403, 'forbidden')),
    true,
  );
  assertEquals(
    isGoogleCalendarForbiddenError(new GoogleCalendarApiError('events.patch', 500, 'unavailable')),
    false,
  );
  assertEquals(isGoogleCalendarForbiddenError(new Error('forbidden')), false);
});

async function revalidateWithCalendarList(items: unknown[]) {
  const originalFetch = globalThis.fetch;
  let rpcArgs: Record<string, unknown> | undefined;
  globalThis.fetch = () => Promise.resolve(new Response(JSON.stringify({ items })));
  try {
    await revalidateCalendarEligibilityAfterForbidden({
      rpc: (_name: string, args: Record<string, unknown>) => {
        rpcArgs = args;
        return Promise.resolve({ data: { eligible: args.p_is_eligible }, error: null });
      },
    } as never, {
      calendarConnectionId: 'connection-1',
      externalCalendarId: 'family@example.com',
      accessToken: 'access-token',
      reason: '403 test',
    });
  } finally {
    globalThis.fetch = originalFetch;
  }
  return rpcArgs;
}

Deno.test('rechecks a 403 against calendarList and retains a still-writer Asia/Tokyo target', async () => {
  const args = await revalidateWithCalendarList([
    { id: 'family@example.com', accessRole: 'writer', timeZone: 'Asia/Tokyo' },
  ]);
  assertEquals(args?.p_is_eligible, true);
});

Deno.test('rechecks a 403 and rejects a reader downgrade', async () => {
  const args = await revalidateWithCalendarList([
    { id: 'family@example.com', accessRole: 'reader', timeZone: 'Asia/Tokyo' },
  ]);
  assertEquals(args?.p_is_eligible, false);
});

Deno.test('rechecks a 403 and rejects a calendar absent from calendarList', async () => {
  const args = await revalidateWithCalendarList([
    { id: 'other@example.com', accessRole: 'owner', timeZone: 'Asia/Tokyo' },
  ]);
  assertEquals(args?.p_is_eligible, false);
});

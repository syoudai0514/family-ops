import { assertEquals } from 'jsr:@std/assert@1';
import {
  GOOGLE_CALENDAR_SCOPES,
  GoogleCalendarApiError,
  googleEventMatchesOperation,
  isRetryableGoogleWriteStatus,
  isLiveCalendarEligible,
  isGoogleCalendarForbiddenError,
  listEligibleCalendarCandidates,
  projectionWindow,
  revalidateCalendarEligibilityAfterForbidden,
} from './googleCalendar.ts';

Deno.test('write reconciliation requires the original operation marker', () => {
  assertEquals(googleEventMatchesOperation({ extendedProperties: { private: { familyOpsOperationId: 'operation-1' } } }, 'operation-1'), true);
  assertEquals(googleEventMatchesOperation({ extendedProperties: { private: { familyOpsOperationId: 'other-operation' } } }, 'operation-1'), false);
  assertEquals(googleEventMatchesOperation({ summary: 'Same title', extendedProperties: null }, 'operation-1'), false);
  assertEquals(googleEventMatchesOperation({}, 'operation-1'), false);
});

Deno.test('temporary write HTTP failures can retry without a terminal dead receipt', () => {
  for (const status of [408, 429, 500, 502, 503, 504]) assertEquals(isRetryableGoogleWriteStatus(status), true);
  for (const status of [200, 201, 400, 401, 403, 404, 409, 412]) assertEquals(isRetryableGoogleWriteStatus(status), false);
});

Deno.test('projection window uses Tokyo midnight boundaries and matching local dates', () => {
  assertEquals(projectionWindow(new Date('2026-10-03T02:30:00Z')), {
    start: '2026-09-25T15:00:00.000Z',
    end: '2026-12-01T15:00:00.000Z',
    startDate: '2026-09-26',
    endDate: '2026-12-02',
  });
});

Deno.test('projection window stays stable within a Tokyo day and advances at local midnight', () => {
  const before = projectionWindow(new Date('2026-10-03T14:59:59Z'));
  assertEquals(before, projectionWindow(new Date('2026-10-02T15:00:00Z')));
  assertEquals(projectionWindow(new Date('2026-10-03T15:00:00Z')), {
    start: '2026-09-26T15:00:00.000Z',
    end: '2026-12-02T15:00:00.000Z',
    startDate: '2026-09-27',
    endDate: '2026-12-03',
  });
});

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

Deno.test('does not infer eligibility when calendarList has a transient error', async () => {
  const originalFetch = globalThis.fetch;
  let rpcCalls = 0;
  globalThis.fetch = () => Promise.resolve(new Response('temporary error', { status: 503 }));
  try {
    const result = await revalidateCalendarEligibilityAfterForbidden({
      rpc: () => {
        rpcCalls++;
        return Promise.resolve({ data: { eligible: false }, error: null });
      },
    } as never, {
      calendarConnectionId: 'connection-1',
      externalCalendarId: 'family@example.com',
      accessToken: 'access-token',
      reason: '403 test',
    });
    assertEquals(result, null);
    assertEquals(rpcCalls, 0);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test('uses the same live predicate for a target candidate and rejects non-Tokyo access', async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = () => Promise.resolve(new Response(JSON.stringify({ items: [
    { id: 'family@example.com', accessRole: 'writer', timeZone: 'America/New_York' },
  ] })));
  try {
    assertEquals(await isLiveCalendarEligible('access-token', 'family@example.com'), false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

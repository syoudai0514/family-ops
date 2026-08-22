import { assertEquals } from 'jsr:@std/assert@1';
import {
  GOOGLE_CALENDAR_SCOPES,
  listEligibleCalendarCandidates,
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

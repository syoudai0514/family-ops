import { assertEquals } from 'jsr:@std/assert@1';
import { formatScheduleDate, leadingScheduleDates } from './scheduleLanguage.ts';
import { decomposeLineConversationCandidates } from './lineMultiIntent.ts';

const now = new Date('2026-10-03T03:00:00Z');
Deno.test('multiple dates are distinct calendar occurrences with weekdays', () => {
  assertEquals(leadingScheduleDates('10/6と10/8、パパ飲み会', now), ['2026-10-06', '2026-10-08']);
  assertEquals(formatScheduleDate('2026-10-06'), '10/6(火)');
  assertEquals(formatScheduleDate('2026-10-08'), '10/8(木)');
  assertEquals(leadingScheduleDates('2/30と10/8', now), ['2026-10-08']);
});
Deno.test('screenshot appointment remains registerable without AI', async () => {
  const candidates = await decomposeLineConversationCandidates('ママ、10/10 16時R形成外科みなとみらい', now, () => Promise.resolve(null));
  assertEquals(candidates.length, 1);
  assertEquals(candidates[0].intent?.scheduledDate, '2026-10-10');
  assertEquals(candidates[0].intent?.dueLocalTime, '16:00');
  assertEquals(candidates[0].intent?.targetRole, 'mama');
  assertEquals(candidates[0].intent?.calendarVisibility, 'special');
});
Deno.test('screenshot party adds both dates without a transport change or invented clock', async () => {
  const candidates = await decomposeLineConversationCandidates('10/6と10/8、パパ飲み会なので予定入れといて。もともとママ迎えだから送迎の変更不要。', now, () => Promise.resolve(null));
  assertEquals(candidates.length, 2);
  assertEquals(candidates.map((candidate) => candidate.intent?.scheduledDate), ['2026-10-06', '2026-10-08']);
  assertEquals(candidates.map((candidate) => candidate.intent?.targetRole), ['papa', 'papa']);
  assertEquals(candidates.map((candidate) => candidate.intent?.daypart), ['night', 'night']);
  assertEquals(candidates.map((candidate) => candidate.intent?.dueLocalTime), [null, null]);
});
Deno.test('an AI result omitting the second occurrence is expanded but an authoritative no-action is retained', async () => {
  const text = '10/6と10/8、パパ飲み会なので予定入れといて。もともとママ迎えだから送迎の変更不要。';
  const provider = () => Promise.resolve(JSON.stringify({candidates:[{kind:'task',title:'パパ飲み会',source_text:text,scheduled_date:'2026-10-06',calendar_visibility:'special'}]}));
  const candidates = await decomposeLineConversationCandidates(text, now, provider);
  assertEquals(candidates.map((candidate) => candidate.intent?.scheduledDate), ['2026-10-06', '2026-10-08']);
  assertEquals(candidates.map((candidate) => candidate.candidateId), ['c1','c2']);
  assertEquals(candidates.map((candidate) => candidate.intent?.targetRole), ['papa','papa']);
  assertEquals(await decomposeLineConversationCandidates(text, now, () => Promise.resolve('{"candidates":[]}')), []);
});

import { assertEquals } from 'jsr:@std/assert@1';
import { transportConsultChoices, validTransportConsultChoice } from './lineTransportConsult.ts';

Deno.test('consult choices bind the day and handle year rollover', () => {
  const choices = transportConsultChoices('2026-12-31');
  assertEquals(choices.map((choice) => choice.label), ['今日の送り', '今日のお迎え', '明日の送り', '明日のお迎え']);
  const tomorrow = new URLSearchParams((choices[3] as { data: string }).data);
  assertEquals(tomorrow.get('date'), '2027-01-01');
  assertEquals(tomorrow.get('code'), 'pickup');
  assertEquals(transportConsultChoices('2026-02-30'), []);
});

Deno.test('only today or tomorrow and known transport kinds can create a draft', () => {
  assertEquals(validTransportConsultChoice({ date: '2027-01-01', code: 'pickup' }, '2026-12-31'), true);
  assertEquals(validTransportConsultChoice({ date: '2026-12-30', code: 'pickup' }, '2026-12-31'), false);
  assertEquals(validTransportConsultChoice({ date: '2027-01-02', code: 'dropoff' }, '2026-12-31'), false);
  assertEquals(validTransportConsultChoice({ date: '2026-12-31', code: 'other' }, '2026-12-31'), false);
});

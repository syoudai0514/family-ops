import { assertEquals } from 'jsr:@std/assert@1';
import { previousDayReminderText } from './previousDayReminder.ts';
import { buildBriefQuickReply } from './briefQuickReply.ts';
Deno.test('unrecorded previous-day work has a dated reminder and a understood reply button', () => {
  assertEquals(previousDayReminderText('2026-10-02', []), null);
  const reminder = previousDayReminderText('2026-10-02', ['洗濯','掃除'])!;
  assertEquals(reminder.includes('10/2(金)'),true);
  assertEquals(reminder.includes('昨日の○○以外は完了'),true);
  assertEquals(buildBriefQuickReply('daily_brief.v2',{previousDay:true})?.[0],{type:'message',label:'昨日は全部完了',text:'昨日のは全部終わっている'});
});

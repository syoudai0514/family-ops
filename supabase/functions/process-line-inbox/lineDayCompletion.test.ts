import { assertEquals } from 'jsr:@std/assert@1';
import { parseDayCompletion, selectDayCompletionTasks, tryHandleDayCompletion } from './lineDayCompletion.ts';
import type { CompletionContext } from './lineCompletionReport.ts';

Deno.test('yesterday, future dates and exclusion are explicit and negatives do not mutate', () => {
  assertEquals(parseDayCompletion('昨日のは全部終わっている', '2026-10-03'), {date:'2026-10-02',except:null});
  assertEquals(parseDayCompletion('昨日の洗濯以外は完了', '2026-10-03'), {date:'2026-10-02',except:'洗濯'});
  assertEquals(parseDayCompletion('明日のは全部やった', '2026-10-03'), {date:'2026-10-04',except:null});
  assertEquals(parseDayCompletion('10/6のは全部完了', '2026-10-03'), {date:'2026-10-06',except:null});
  for (const text of ['昨日全部終わってない','昨日全部完了？','昨日全部終わったら','昨日全部完了予定','2/30のは全部完了']) assertEquals(parseDayCompletion(text, '2026-10-03'), null);
});
const tasks = [{id:'a',title:'洗濯',code:null,due_at:null,revision:1},{id:'b',title:'掃除',code:null,due_at:null,revision:1}];
Deno.test('an exclusion must identify exactly one task before any updates', () => {
  assertEquals(selectDayCompletionTasks(tasks,'洗濯'), [tasks[1]]);
  assertEquals(selectDayCompletionTasks(tasks,'炊事'), null);
  assertEquals(selectDayCompletionTasks([...tasks,{...tasks[0],id:'c',title:'洗濯をたたむ'}],'洗濯'), null);
});
Deno.test('a dated bulk report reads exactly that day and ordinary completions use canonical RPCs', async () => {
  const filters: Array<[string,unknown]> = [];
  const calls: Array<{name:string;payload:Record<string,unknown>}> = [];
  const replies: string[] = [];
  const rows = [...tasks.map((task) => ({...task,planned_assignee_id:'me',task_definition_id:null})),{id:'c',title:'コドモン送信',revision:1,due_at:null,planned_assignee_id:'me',task_definition_id:'codmon'}];
  const client = {
    from: (table:string) => {
      const result = {data:table==='task_instances'?rows:[{id:'codmon',code:'codmon_submit'}],error:null};
      const chain = {select:()=>chain,eq:(key:string,value:unknown)=>{filters.push([key,value]);return chain;},is:()=>chain,in:()=>chain,limit:()=>chain,then:(resolve:(result:unknown)=>unknown)=>Promise.resolve(result).then(resolve)};
      return chain;
    },
    rpc:(name:string,payload:Record<string,unknown>)=>{calls.push({name,payload});return Promise.resolve({data:{revision:2},error:null});},
  };
  const ctx = {client,actorId:'me',householdId:'hh',today:'2026-10-03',operationId:(...parts:string[])=>Promise.resolve(parts.join(':')),reply:(text:string)=>{replies.push(text);return Promise.resolve();}} as unknown as CompletionContext;
  assertEquals(await tryHandleDayCompletion(ctx,'昨日の洗濯以外は完了'),true);
  assertEquals(filters.find(([key])=>key==='scheduled_date')?.[1],'2026-10-02');
  assertEquals(calls.map((call)=>call.payload.p_task_id),['b']);
  assertEquals(calls[0].name,'server_tx_complete_task');
  assertEquals(replies[0].includes('コドモンは送信まで済みましたか'),true);
});

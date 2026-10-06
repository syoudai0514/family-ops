import { assertEquals } from 'jsr:@std/assert@1';
import { codmonAnswer, codmonQuestionDate, parseDayCompletion, selectDayCompletionTasks, tryHandleDayCompletion } from './lineDayCompletion.ts';
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

Deno.test('the yesterday Codmon question names its date, and a short answer closes that day only', async () => {
  // 2026-10-07: 「終わっている」 after "10/6(火)のコドモンは送信まで済みましたか？" closed nine of today's tasks.
  assertEquals(codmonQuestionDate('10/6(火) の記録\n✓ 「送り」を完了にしました。\n10/6(火)のコドモンは送信まで済みましたか？', '2026-10-07'), '2026-10-06');
  assertEquals(codmonQuestionDate('12/31(木)のコドモンは送信まで済みましたか？', '2027-01-01'), '2026-12-31');
  assertEquals(codmonQuestionDate('コドモンは送信まで済んだ？', '2026-10-07'), null);
  for (const yes of ['終わっている', '送信してます', '送った！', 'はい', '済んでる']) assertEquals(codmonAnswer(yes), true, yes);
  for (const no of ['まだ', 'してない', '送ってないよ']) assertEquals(codmonAnswer(no), false, no);
  for (const other of ['朝の全部やった', '牛乳買って', '']) assertEquals(codmonAnswer(other), null, other);

  const filters: Array<[string, unknown]> = [];
  const calls: Array<{ name: string; payload: Record<string, unknown> }> = [];
  const replies: string[] = [];
  const client = {
    from: (table: string) => {
      const result = {
        data: table === 'task_instances'
          ? [{ id: 'submit-1006', title: 'コドモン送信', revision: 1, due_at: null, planned_assignee_id: null, task_definition_id: 'codmon' }]
          : [{ id: 'codmon', code: 'codmon_submit' }],
        error: null,
      };
      const chain = { select: () => chain, eq: (key: string, value: unknown) => { filters.push([key, value]); return chain; }, is: () => chain, in: () => chain, neq: () => chain, limit: () => chain, then: (resolve: (r: unknown) => unknown) => Promise.resolve(result).then(resolve) };
      return chain;
    },
    rpc: (name: string, payload: Record<string, unknown>) => {
      calls.push({ name, payload });
      if (name === 'server_read_line_turns') {
        return Promise.resolve({ data: [{ role: 'user', text: '昨日のは全部終わっている' }, { role: 'assistant', text: '10/6(火) の記録\n10/6(火)のコドモンは送信まで済みましたか？' }], error: null });
      }
      return Promise.resolve({ data: { revision: 2, inputs_closed: 0 }, error: null });
    },
  };
  const ctx = { client, actorId: 'me', householdId: 'hh', today: '2026-10-07', operationId: (...p: string[]) => Promise.resolve(p.join(':')), reply: (t: string) => { replies.push(t); return Promise.resolve(); } } as unknown as CompletionContext;
  assertEquals(await tryHandleDayCompletion(ctx, '終わっている'), true);
  assertEquals(filters.filter(([key]) => key === 'scheduled_date').map(([, v]) => v), ['2026-10-06']);
  assertEquals(calls.filter((c) => c.name.startsWith('server_tx_')).map((c) => [c.name, c.payload.p_submit_task_id]), [['server_tx_acknowledge_codmon_submission_v1', 'submit-1006']]);
  assertEquals(replies[0].startsWith('10/6(火) の記録'), true);

  // Not after that question: left to the normal path (nothing done here).
  calls.length = 0;
  const plain = { ...ctx, client: { ...client, rpc: (name: string, payload: Record<string, unknown>) => { calls.push({ name, payload }); return Promise.resolve({ data: [{ role: 'assistant', text: 'おつかれさま！' }], error: null }); } } } as unknown as CompletionContext;
  assertEquals(await tryHandleDayCompletion(plain, '終わっている'), false);
  assertEquals(calls.filter((c) => c.name.startsWith('server_tx_')).length, 0);
});

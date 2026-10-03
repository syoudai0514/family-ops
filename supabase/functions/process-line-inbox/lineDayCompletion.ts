import { completeTaskAndReply, loadOpenTasks, type CompletionContext, type OpenTask } from './lineCompletionReport.ts';
import { formatScheduleDate } from './scheduleLanguage.ts';

export type DayCompletionReport = { date: string; except: string | null };
export function completionDate(text: string, today: string): string | null {
  const value = text.normalize('NFKC').trim();
  if (!/^(昨日|一昨日|今日|明日|\d{1,2}\/\d{1,2})[^。！？?]*?(?:終わ|完了|やった|済|送った|送信した|送りました)/u.test(value)) return null;
  const token = value.match(/^(昨日|一昨日|今日|明日|\d{1,2}\/\d{1,2})/u)![1];
  return parseDayCompletion(`${token}のは全部完了`, today)?.date ?? null;
}
export function parseDayCompletion(text: string, today: string): DayCompletionReport | null {
  const value = text.normalize('NFKC').replace(/\s/gu, '').replace(/[。!！よねだ]+$/u, '').replace(/^(昨日|一昨日|今日|明日)の?(?:タスク|作業|やること)/u, '$1の');
  if (/[?？]|未完了|まだ|してない|終わってない|終わっていない|完了にしない|予定|つもり/u.test(value)) return null;
  const match = value.match(/^(昨日|一昨日|今日|明日|\d{1,2}\/\d{1,2})(?:の)?(?:は)?(?:(全部|すべて)|(.+?)以外(?:は|のは)?(?:全部|すべて)?)(?:終わって(?:いる|います|る)|終わった|終わりました|完了(?:した|しました|です)?|済んだ|やった)$/u);
  if (!match) return null;
  const base = new Date(`${today}T00:00:00Z`);
  if (/\//u.test(match[1])) {
    const [month, day] = match[1].split('/').map(Number);
    base.setUTCMonth(month - 1, day);
    if (base.getUTCMonth() !== month - 1 || base.getUTCDate() !== day) return null;
  } else base.setUTCDate(base.getUTCDate() + ({昨日: -1, 一昨日: -2, 今日: 0, 明日: 1}[match[1]] ?? 0));
  return { date: base.toISOString().slice(0, 10), except: match[3] ?? null };
}

export function selectDayCompletionTasks(tasks: OpenTask[], except: string | null): OpenTask[] | null {
  if (!except) return tasks;
  const hints = except.split(/と|、|,|・/u).map((hint) => hint.replace(/(?:の)?タスク$/u, '').trim()).filter(Boolean);
  if (!hints.length) return null;
  const excluded = new Set<string>();
  for (const hint of hints) {
    const matches = tasks.filter((task) => task.title.normalize('NFKC').replace(/\s/gu, '').includes(hint));
    if (matches.length !== 1) return null;
    excluded.add(matches[0].id);
  }
  return tasks.filter((task) => !excluded.has(task.id));
}

export async function tryHandleDayCompletion(ctx: CompletionContext, text: string): Promise<boolean> {
  let report = parseDayCompletion(text, ctx.today);
  if (!report && !/昨日|今日|明日|一昨日|\d+\//u.test(text) && /以外|全部|すべて/u.test(text)) {
    const { data, error } = await ctx.client.rpc('server_read_line_turns', { p_actor_id: ctx.actorId, p_limit: 4 });
    const turns = !error && Array.isArray(data) ? data as Array<{ role: string; text: string }> : [];
    const last = turns.filter((turn) => turn.role === 'assistant').at(-1);
    const date = last?.text.match(/昨日（(\d{4}-\d{2}-\d{2})）の更新確認/u)?.[1];
    const yesterday = new Date(`${ctx.today}T00:00:00Z`);
    yesterday.setUTCDate(yesterday.getUTCDate() - 1);
    if (date === yesterday.toISOString().slice(0, 10)) report = parseDayCompletion(`昨日の${text}`, ctx.today);
  }
  if (!report) return false;
  const dayContext = { ...ctx, today: report.date };
  const tasks = await loadOpenTasks(dayContext);
  const selected = selectDayCompletionTasks(tasks, report.except);
  if (!selected) {
    await ctx.reply(`「${report.except}」を1つの作業に特定できませんでした。${formatScheduleDate(report.date)}のどの作業を残すか、正式な名前で教えてください。変更はしていません。`);
    return true;
  }
  const parts: string[] = [];
  // A bulk actual report never makes a claim that Codmon was sent.
  for (const task of selected.filter((task) => task.code !== 'codmon_submit')) {
    await completeTaskAndReply({ ...dayContext, reply: async (message) => { parts.push(message); } }, task.id, {
      operationId: await ctx.operationId('day-completion', report.date, task.id), title: task.title, code: task.code,
    });
  }
  const submit = selected.find((task) => task.code === 'codmon_submit');
  const lead = `${formatScheduleDate(report.date)} の記録`;
  if (submit) parts.push('コドモンは送信まで済みましたか？');
  if (!parts.length) parts.push('更新する未完了の作業はありません。');
  await ctx.reply([lead, ...parts].join('\n'), submit ? [{ type: 'postback', label: '送信した', data: `action=complete_task&task_id=${submit.id}`, displayText: `${formatScheduleDate(report.date)}のコドモンを送信した` }] : undefined);
  return true;
}

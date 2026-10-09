import { completeTaskAndReply, loadOpenTasks, type CompletionContext, type OpenTask } from './lineCompletionReport.ts';
import { formatScheduleDate } from './scheduleLanguage.ts';
import type { LineQuickReplyAction } from '../_shared/lineMessaging.ts';

export type DayCompletionReport = { date: string; except: string | null; owner: string | null };
export function completionDate(text: string, today: string): string | null {
  const value = text.normalize('NFKC').trim();
  if (!/^(昨日|一昨日|今日|明日|\d{1,2}\/\d{1,2})[^。！？?]*?(?:終わ|完了|やった|済|送った|送信した|送りました)/u.test(value)) return null;
  const token = value.match(/^(昨日|一昨日|今日|明日|\d{1,2}\/\d{1,2})/u)![1];
  return parseDayCompletion(`${token}のは全部完了`, today)?.date ?? null;
}
export function parseDayCompletion(text: string, today: string): DayCompletionReport | null {
  const value = text.normalize('NFKC').replace(/\s/gu, '').replace(/[。!！よねだ]+$/u, '').replace(/^(昨日|一昨日|今日|明日)の?(?:タスク|作業|やること)/u, '$1の');
  if (/[?？]|未完了|まだ|してない|終わってない|終わっていない|完了にしない|予定|つもり/u.test(value)) return null;
  const match = value.match(/^(昨日|一昨日|今日|明日|\d{1,2}\/\d{1,2})(?:の)?(?:(パパ|ママ|自分|わたし|私|おれ|俺|ぼく|僕)の)?(?:は)?(?:(全部|すべて)|(.+?)以外(?:は|のは)?(?:全部|すべて)?)(?:終わって(?:いる|います|ます|る)|終わった|終わりました|完了(?:した|しました|です)?|済んだ|やった)$/u);
  if (!match) return null;
  const base = new Date(`${today}T00:00:00Z`);
  if (/\//u.test(match[1])) {
    const [month, day] = match[1].split('/').map(Number);
    base.setUTCMonth(month - 1, day);
    if (base.getUTCMonth() !== month - 1 || base.getUTCDate() !== day) return null;
  } else base.setUTCDate(base.getUTCDate() + ({昨日: -1, 一昨日: -2, 今日: 0, 明日: 1}[match[1]] ?? 0));
  return { date: base.toISOString().slice(0, 10), except: match[4] ?? null, owner: match[2] ?? null };
}

export function selectDayCompletionTasks(allTasks: OpenTask[], except: string | null): OpenTask[] | null {
  // "全部終わった" never claims 余裕があれば (optional) work was done, as in the app.
  const tasks = allTasks.filter((task) => !task.optional);
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

const CODMON_QUESTION = /(\d{1,2})\/(\d{1,2})\([日月火水木金土]\)のコドモンは送信まで済みましたか[?？]/u;

/**
 * The date a "M/D(曜)のコドモンは送信まで済みましたか？" question was about (JST yyyy-mm-dd),
 * read from the bot's own previous turn. 2026-10-07: the answer 「終わっている」 to the
 * question about 10/6 was taken as "this morning's tasks are done" and closed nine of
 * today's tasks; the answer belongs to the day that was asked about.
 */
export function codmonQuestionDate(assistantText: string | undefined, today: string): string | null {
  const m = assistantText?.normalize("NFKC").match(CODMON_QUESTION);
  if (!m) return null;
  const month = Number(m[1]);
  const day = Number(m[2]);
  const [year, todayMonth] = today.split("-").map(Number);
  const date = new Date(Date.UTC(month > todayMonth ? year - 1 : year, month - 1, day));
  if (date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null;
  return date.toISOString().slice(0, 10);
}

/** A short answer to that question: true = sent, false = not yet, null = something else. */
export function codmonAnswer(text: string): boolean | null {
  const value = text.normalize("NFKC").replace(/\s/gu, "").replace(/[。!！よねー〜]+$/u, "");
  if (value.length === 0 || value.length > 20) return null;
  if (/^(?:まだ|いや|いいえ|ううん|してない|送ってない|送れてない|終わってない|済んでない|未送信)/u.test(value)) return false;
  if (/^(?:はい|うん|うい|OK|おk|済み|済んだ|済んでる|済んでいる|済みです|送った|送りました|送信した|送信しました|送信してます|送信している|送信済み|した|しました|してる|しています|終わった|終わってる|終わっている|終わってます|終わりました|完了|完了です|大丈夫)$/iu.test(value)) return true;
  return null;
}

export async function tryHandleDayCompletion(ctx: CompletionContext, text: string): Promise<boolean> {
  if (await tryAnswerCodmonQuestion(ctx, text)) return true;
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
  // "昨日のパパのは全部…": the sender's own work. Another person's list is not closed here.
  if (report.owner && !(await ownerIsSender(ctx, report.owner))) return false;
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
    await completeTaskAndReply({ ...dayContext, reply: (message) => { parts.push(message); return Promise.resolve(); } }, task.id, {
      operationId: await ctx.operationId('day-completion', report.date, task.id), title: task.title, code: task.code,
    });
  }
  const submit = selected.find((task) => task.code === 'codmon_submit');
  const lead = `${formatScheduleDate(report.date)} の記録`;
  if (submit) parts.push(`${formatScheduleDate(report.date)}のコドモンは送信まで済みましたか？`);
  if (!parts.length) parts.push('更新する未完了の作業はありません。');
  await ctx.reply([lead, ...parts].join('\n'), submit ? [{ type: 'postback', label: '送信した', data: `action=complete_task&task_id=${submit.id}`, displayText: `${formatScheduleDate(report.date)}のコドモンを送信した` }] : undefined);
  return true;
}

/** "終わっている" right after "10/6(火)のコドモンは送信まで済みましたか？" closes 10/6's submit, nothing of today. */
async function tryAnswerCodmonQuestion(ctx: CompletionContext, text: string): Promise<boolean> {
  const answer = codmonAnswer(text);
  if (answer === null) return false;
  const { data, error } = await ctx.client.rpc('server_read_line_turns', { p_actor_id: ctx.actorId, p_limit: 4 });
  const turns = !error && Array.isArray(data) ? data as Array<{ role: string; text: string }> : [];
  const date = codmonQuestionDate(turns.filter((turn) => turn.role === 'assistant').at(-1)?.text, ctx.today);
  if (!date || date === ctx.today) return false;
  const label = formatScheduleDate(date);
  if (!answer) {
    await ctx.reply(`了解。${label}のコドモン送信は未完了のままにしています。`);
    return true;
  }
  const submit = (await loadOpenTasks({ ...ctx, today: date })).find((task) => task.code === 'codmon_submit');
  if (!submit) {
    await ctx.reply(`${label}のコドモン送信は、すでに完了になっています。今日の作業は変えていません。`);
    return true;
  }
  const dated = { ...ctx, today: date, reply: (message: string, quick?: LineQuickReplyAction[]) => ctx.reply(`${label} の記録\n${message}`, quick) };
  await completeTaskAndReply(dated, submit.id, {
    operationId: await ctx.operationId('day-completion-codmon', date, submit.id),
    title: submit.title,
    code: submit.code,
  });
  return true;
}

const OWNER_ROLE: Record<string, string> = { パパ: 'papa', ママ: 'mama' };

/** "パパの" is the sender only when the sender is the papa; 自分・私・俺… always are. */
async function ownerIsSender(ctx: CompletionContext, owner: string): Promise<boolean> {
  const role = OWNER_ROLE[owner];
  if (!role) return true;
  const { data } = await ctx.client.from('household_members').select('family_role').eq('household_id', ctx.householdId).eq('user_id', ctx.actorId).maybeSingle();
  return (data as { family_role?: string | null } | null)?.family_role === role;
}

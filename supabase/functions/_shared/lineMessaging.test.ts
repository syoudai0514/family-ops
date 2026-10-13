import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { buildLineMessages, buildLinePushMessages, replyOrEnqueuePush, type LineQuickReplyAction } from './lineMessaging.ts';
import { splitLineText } from './lineTextMessages.ts';
import { buildBundledText } from '../send-notifications/bundledText.ts';
import { formatTodayTasks } from '../process-line-inbox/lineTodayTasks.ts';

const quick: LineQuickReplyAction[] = [{ type: 'message', label: '今日を見る', text: '今日のタスク' }];
const footer = '詳しく見る\n・今日の一覧 https://family-ops-web.vercel.app/today';
function joinedText(messages: Record<string, unknown>[]) {
  return messages.filter((message) => message.type === 'text').map((message) => message.text as string).join('');
}
function assertValid(messages: Record<string, unknown>[]) {
  assertEquals(messages.length > 0 && messages.length <= 5, true);
  for (const message of messages) {
    if (message.type !== 'text') continue;
    const text = message.text as string;
    assertEquals(text.length > 0 && text.length <= 5000, true);
    assertEquals(text.isWellFormed(), true);
  }
}

Deno.test('250 long task titles are preserved across the LINE budget, with the footer and last quick reply', () => {
  const rows = Array.from({ length: 250 }, (_, index) => ({
    title: `${String(index + 1).padStart(3, '0')}番の用事：${'持ち物を確かめて準備する'.repeat(5)}🧒`,
    status: 'todo', routine_phase: 'morning', planned_assignee_id: 'me',
  }));
  const text = `${formatTodayTasks(rows, 'me', 'パパ', 'ママ')}\n\n${footer}`;
  const messages = buildLineMessages(text, quick, undefined, '今日の作業を確認しました。');
  assertValid(messages);
  for (const row of rows) assertStringIncludes(joinedText(messages), row.title);
  assertEquals(messages.slice(0, -1).some((message) => Boolean(message.quickReply)), false);
  assertEquals(Boolean(messages.at(-1)?.quickReply), true);
  assertEquals((messages.at(-1)?.text as string).endsWith(footer), true);
  assertEquals(joinedText(messages).includes('…続きは'), false);
});

Deno.test('long single lines and surrogate boundaries are split without losing characters', () => {
  const text = `x${'🧒'.repeat(6000)}\n${'準備'.repeat(2500)}`;
  const chunks = splitLineText(text);
  assertEquals(chunks.join(''), text);
  assertEquals(chunks.every((chunk) => chunk.length <= 5000 && chunk.isWellFormed()), true);
  const full = `x${'🧒'.repeat(12499)}x`;
  const bounded = splitLineText(full);
  assertEquals(bounded.every((chunk) => chunk.length <= 5000 && chunk.isWellFormed()), true);
  assertEquals(bounded.length <= 5, true);
  assertStringIncludes(bounded.join(''), '…続きはアプリで確認してください。');
});

Deno.test('over-budget lists explain the omission and retain the original detail links', () => {
  const text = `${'・長い用事をここで確認する\n'.repeat(3000)}\n${footer}`;
  const messages = buildLineMessages(text, quick);
  assertValid(messages);
  assertStringIncludes(joinedText(messages), '…続きはアプリで確認してください。');
  assertEquals((messages.at(-1)?.text as string).endsWith(footer), true);
});

Deno.test('leading text and Flex cards respect the five-message budget and put quick replies last', () => {
  const rich = { type: 'flex', altText: '内容を確認', contents: { type: 'bubble', body: { type: 'box', layout: 'vertical', contents: [] } } };
  const reply = buildLineMessages('fallback summary', quick, rich, '案内'.repeat(11000));
  assertValid(reply);
  assertEquals(reply.length, 5);
  assertEquals(reply.at(-1)?.type, 'flex');
  assertEquals(Boolean(reply.at(-1)?.quickReply), true);
  assertEquals('quickReply' in rich, false);
  const push = buildLinePushMessages('準備\n'.repeat(4000), quick, rich);
  assertValid(push);
  assertEquals(joinedText(push), '準備\n'.repeat(4000));
  assertEquals(push.at(-1)?.type, 'flex');
  assertEquals(Boolean(push.at(-1)?.quickReply), true);
});

Deno.test('push bundling preserves long content and one check-in link per session before splitting', () => {
  const oldBase = Deno.env.get('APP_BASE_URL');
  Deno.env.set('APP_BASE_URL', 'https://family-ops-web.vercel.app');
  try {
    const body = '確認する作業\n'.repeat(1200);
    const bundle = buildBundledText({ items: [{ title: '朝のおうちノート', body }, { title: '共有', body: '追加の共有' }] }, 'daily_brief.v2', 'papa');
    const messages = buildLinePushMessages(bundle.text, quick);
    assertValid(messages);
    assertEquals(joinedText(messages), bundle.text);
    assertStringIncludes(joinedText(messages), body);
    assertEquals((messages.at(-1)?.text as string).endsWith('https://family-ops-web.vercel.app/today?for=papa'), true);
    const routine = buildBundledText({ items: [{ title: '朝', session_id: 'session' }, { title: '追加', session_id: 'session' }] }, 'routine');
    assertEquals(routine.sessionIds, ['session']);
    assertEquals(routine.text.match(/\/checkin\/session/g)?.length, 1);
  } finally {
    if (oldBase === undefined) Deno.env.delete('APP_BASE_URL'); else Deno.env.set('APP_BASE_URL', oldBase);
  }
});

Deno.test('reply-first sends one valid request; an expired token durably retains the complete fallback text', async () => {
  const oldFetch = globalThis.fetch;
  const oldToken = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN');
  Deno.env.set('LINE_CHANNEL_ACCESS_TOKEN', 'test-channel-token');
  let request: Record<string, unknown> | undefined;
  let status = 200;
  let saved: Record<string, unknown> | undefined;
  globalThis.fetch = (_input, init) => {
    request = JSON.parse(String((init as { body?: unknown } | undefined)?.body));
    return Promise.resolve(new Response('{}', { status }));
  };
  const client = { rpc: (_name: string, args: Record<string, unknown>) => { saved = args; return Promise.resolve({ error: null }); } } as unknown as SupabaseClient;
  const text = `${'作業と準備\n'.repeat(1000)}\n${footer}`;
  const args = { replyToken: 'test-reply', lineUserId: 'test-user', householdId: 'household', recipientUserId: 'me', text, quickReplyItems: quick };
  try {
    assertEquals(await replyOrEnqueuePush(client, args), 'replied');
    assertValid(request?.messages as Record<string, unknown>[]);
    assertEquals(joinedText(request?.messages as Record<string, unknown>[]), text);
    assertEquals(saved, undefined);
    status = 400;
    assertEquals(await replyOrEnqueuePush(client, args), 'push_fallback');
    assertEquals(saved?.p_text, text);
    const bundle = buildBundledText({ items: [{ title: saved?.p_text as string }] }, 'line_reply_fallback');
    const messages = buildLinePushMessages(bundle.text);
    assertValid(messages);
    assertEquals(joinedText(messages), text);
  } finally {
    globalThis.fetch = oldFetch;
    if (oldToken === undefined) Deno.env.delete('LINE_CHANNEL_ACCESS_TOKEN'); else Deno.env.set('LINE_CHANNEL_ACCESS_TOKEN', oldToken);
  }
});

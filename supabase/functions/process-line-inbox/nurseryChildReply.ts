import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import type { LineQuickReplyAction } from '../_shared/lineMessaging.ts';
import { clipScheduleText } from './lineSchedulePage.ts';

export type ChildContext = { id: string; name: string; aliases: string[] | null };
type Pending = { id: string; revision: number; contexts: ChildContext[] };
type Reply = (text: string, actions?: LineQuickReplyAction[]) => Promise<void>;

const normalized = (value: string) => value.normalize('NFKC').replace(/[\s！!。]/gu, '').toLowerCase();

export function matchChild(text: string, contexts: ChildContext[]): ChildContext | null {
  const value = normalized(text);
  const matches = contexts.filter((context) =>
    [context.name, ...(context.aliases ?? [])].some((name) => {
      const n = normalized(name);
      if (!n) return false;
      return value === n || (value.startsWith(n) && /^(の(?:です|やつ|お知らせ|保育園からの依頼)?|です)$/u.test(value.slice(n.length)));
    })
  );
  return matches.length === 1 ? matches[0] : null;
}

export function childButtons(pending: Pending): LineQuickReplyAction[] {
  return pending.contexts.slice(0, 13).map((context) => ({
    type: 'postback',
    label: clipScheduleText(context.name, 20),
    data: new URLSearchParams({ action: 'nursery_choose_child', intake: pending.id, revision: String(pending.revision), context: context.id }).toString(),
    displayText: clipScheduleText(context.name, 300),
  }));
}

export async function pendingChild(client: SupabaseClient, actorId: string, lineUserId: string): Promise<Pending | null> {
  try {
    const { data, error } = await client.rpc('server_read_line_nursery_child_context', {
      p_actor_id: actorId, p_line_user_id: lineUserId,
    });
    return error || !data ? null : data as Pending;
  } catch {
    return null;
  }
}

export async function resolveChild(client: SupabaseClient, actorId: string, pending: Pending, child: ChildContext, reply: Reply, appBase: string): Promise<void> {
  const { data, error } = await client.rpc('server_tx_resolve_nursery_ambiguity', {
    p_actor_id: actorId, p_intake_id: pending.id, p_expected_revision: pending.revision,
    p_child_school_context_id: child.id, p_resolved_fields: ['child'],
  });
  if (error) {
    await reply('確認中の写真が更新されました。最新の内容を開いてください。');
    return;
  }
  const link = appBase.replace(/\/$/, '');
  const status = data?.status === 'review_ready' ? '内容を確認して登録してください。' : '続きはアプリで確認してください。';
  await reply(`${child.name}のお知らせですね。\n${status}${link ? `\n${link}/nursery/reviews/${pending.id}` : ''}`);
}

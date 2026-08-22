// verify_jwt=false — worker class. Converts draft LINE inputs into structured
// pending actions and sends a sender-side LINE preview. No business mutation is
// executed here: the existing confirm_pending postback must still happen first.
import { createServiceRoleClient, requireWorkerToken } from '../_shared/auth.ts';
import { withServiceHandler, jsonResponse } from '../_shared/handler.ts';
import { buildPendingActionPreviewFlex } from '../_shared/lineMessageBuilders.ts';
import { daypartLabel, daypartToLocalTime, extractLineIntent } from '../process-line-inbox/lineIntent.ts';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

const BATCH_LIMIT = Number(Deno.env.get('LINE_DRAFT_BATCH_LIMIT') ?? '20');

type DraftRow = {
  id: string;
  household_id: string;
  actor_id: string;
  action_type: string;
  normalized_payload: Record<string, unknown>;
};

type Prepared = {
  actionType: 'shopping_item_add' | 'task_create_once' | 'request_create';
  payload: Record<string, unknown>;
  kindLabel: string;
  targetLabel: string;
};

async function userForRole(
  client: SupabaseClient,
  householdId: string,
  role: 'papa' | 'mama',
): Promise<string | null> {
  const { data, error } = await client
    .from('household_members')
    .select('user_id')
    .eq('household_id', householdId)
    .eq('family_role', role)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return data?.user_id ?? null;
}

async function partnerUserId(
  client: SupabaseClient,
  householdId: string,
  actorId: string,
): Promise<string | null> {
  const { data, error } = await client
    .from('household_members')
    .select('user_id')
    .eq('household_id', householdId)
    .neq('user_id', actorId)
    .limit(1)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return data?.user_id ?? null;
}

function scheduleLabel(payload: Record<string, unknown>): string {
  const date = typeof payload.scheduled_date === 'string' ? payload.scheduled_date : '';
  const daypart = typeof payload.daypart === 'string' ? payload.daypart : null;
  const time = typeof payload.due_local_time === 'string' ? payload.due_local_time : null;
  let dateLabel = date;
  if (/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    dateLabel = `${Number(date.slice(5, 7))}/${Number(date.slice(8, 10))}`;
  }
  const part = daypart && ['morning', 'noon', 'evening', 'night'].includes(daypart)
    ? daypartLabel(daypart as 'morning' | 'noon' | 'evening' | 'night')
    : (time ?? '時刻なし');
  return `${dateLabel || '今日'} ${part}`;
}

async function prepareDraft(client: SupabaseClient, row: DraftRow): Promise<Prepared | null> {
  const original = { ...row.normalized_payload };

  // The old deterministic parser already recognized these two safe subsets.
  // Keep its title/date instead of reparsing, but add canonical assignee/preview metadata.
  if (row.action_type === 'task_create_once') {
    return {
      actionType: 'task_create_once',
      payload: {
        ...original,
        planned_assignee_user_id: original.planned_assignee_user_id ?? row.actor_id,
        category: original.category ?? 'todo',
        routine_phase: original.routine_phase ?? 'anytime',
        target_label: '自分',
      },
      kindLabel: 'タスク',
      targetLabel: '自分',
    };
  }
  if (row.action_type === 'shopping_item_add') {
    return {
      actionType: 'shopping_item_add',
      payload: { ...original, target_label: original.target_label ?? '買い物リスト' },
      kindLabel: '買い物',
      targetLabel: '買い物リスト',
    };
  }

  const rawText = typeof original.raw_text === 'string' ? original.raw_text.trim() : '';
  if (!rawText) return null;
  const intent = await extractLineIntent(rawText);
  if (!intent) return null;

  const roleUser = intent.targetRole
    ? await userForRole(client, row.household_id, intent.targetRole)
    : null;
  const targetLabel = intent.targetRole === 'papa'
    ? 'パパ'
    : intent.targetRole === 'mama' ? 'ママ' : null;
  const dueLocalTime = daypartToLocalTime(intent.daypart);

  if (intent.kind === 'shopping') {
    // Shopping remains a list item; assigning it to another member does not
    // auto-create a spouse task. Explicit request wording is handled as a
    // request by the intent extractor before this point.
    return {
      actionType: 'shopping_item_add',
      payload: {
        raw_text: rawText,
        title: intent.title,
        purchase_method: /amazon|アマゾン/i.test(rawText) ? 'amazon' : 'store',
        assignee_user_id: roleUser,
        scheduled_date: intent.scheduledDate,
        due_local_time: dueLocalTime,
        daypart: intent.daypart,
        target_label: targetLabel ?? '買い物リスト',
        parse_source: intent.source,
      },
      kindLabel: '買い物',
      targetLabel: targetLabel ?? '買い物リスト',
    };
  }

  const requestedRecipient = roleUser ?? (intent.kind === 'request'
    ? await partnerUserId(client, row.household_id, row.actor_id)
    : null);

  // An explicit other-person target is always a request. Never silently put a
  // task on the partner's list just because a natural-language parser inferred a name.
  if (requestedRecipient && requestedRecipient !== row.actor_id) {
    return {
      actionType: 'request_create',
      payload: {
        raw_text: rawText,
        title: intent.title,
        shared_message: intent.sharedMessage ?? `${intent.title}をお願いできますか？`,
        recipient_user_id: requestedRecipient,
        scheduled_date: intent.scheduledDate,
        due_local_time: dueLocalTime,
        daypart: intent.daypart,
        target_label: targetLabel ?? 'パートナー',
        parse_source: intent.source,
      },
      kindLabel: 'お願い',
      targetLabel: targetLabel ?? 'パートナー',
    };
  }

  return {
    actionType: 'task_create_once',
    payload: {
      raw_text: rawText,
      title: intent.title,
      category: 'todo',
      scheduled_date: intent.scheduledDate,
      due_local_time: dueLocalTime,
      planned_assignee_user_id: row.actor_id,
      routine_phase: 'anytime',
      daypart: intent.daypart,
      target_label: targetLabel ?? '自分',
      parse_source: intent.source,
    },
    kindLabel: 'タスク',
    targetLabel: targetLabel ?? '自分',
  };
}

async function enqueuePreview(
  client: SupabaseClient,
  row: DraftRow,
  prepared: Prepared,
): Promise<void> {
  const { error } = await client.rpc('server_tx_enqueue_immediate_line_push', {
    p_household_id: row.household_id,
    p_recipient_user_id: row.actor_id,
    p_text: `確認: ${String(prepared.payload.title ?? '')}`,
    p_dedup_key: `line-natural-preview:${row.id}`,
    p_rich_message: buildPendingActionPreviewFlex({
      pendingActionId: row.id,
      kindLabel: prepared.kindLabel,
      title: String(prepared.payload.title ?? '予定'),
      scheduleLabel: scheduleLabel(prepared.payload),
      targetLabel: prepared.targetLabel,
      confirmLabel: prepared.actionType === 'request_create' ? 'この内容で送る' : 'この内容で登録',
    }),
  });
  if (error) throw new Error(error.message);
}

async function enqueueClarification(client: SupabaseClient, row: DraftRow): Promise<void> {
  const { error } = await client.rpc('server_tx_enqueue_immediate_line_push', {
    p_household_id: row.household_id,
    p_recipient_user_id: row.actor_id,
    p_text: '予定にうまく変換できませんでした。「明日の朝、歯医者の予約をママにお願い」のように、いつ・何を・誰がを入れてもう一度送ってください。入力はアプリの判断待ちにも残しています。',
    p_dedup_key: `line-natural-clarify:${row.id}`,
    p_rich_message: null,
  });
  if (error) throw new Error(error.message);
}

Deno.serve(
  withServiceHandler(async (req: Request) => {
    requireWorkerToken(req);
    const client = createServiceRoleClient();
    const { data, error } = await client.rpc('server_tx_claim_line_draft_batch', {
      p_limit: BATCH_LIMIT,
    });
    if (error) throw new Error(error.message);

    const rows = (data ?? []) as DraftRow[];
    let previewed = 0;
    let ambiguous = 0;
    let failed = 0;

    for (const row of rows) {
      try {
        const prepared = await prepareDraft(client, row);
        if (!prepared) {
          await enqueueClarification(client, row);
          await client.rpc('server_tx_mark_line_pending_parse_failed', { p_id: row.id });
          ambiguous++;
          continue;
        }
        const { data: ready, error: prepareError } = await client.rpc(
          'server_tx_prepare_line_pending_preview',
          {
            p_id: row.id,
            p_action_type: prepared.actionType,
            p_normalized_payload: prepared.payload,
          },
        );
        if (prepareError) throw new Error(prepareError.message);
        const readyRow = ready as DraftRow;
        await enqueuePreview(client, readyRow, prepared);
        const { error: markError } = await client.rpc('server_tx_mark_line_pending_previewed', {
          p_id: row.id,
        });
        if (markError) throw new Error(markError.message);
        previewed++;
      } catch (err) {
        failed++;
        console.error('process-line-drafts: item failed', {
          id: row.id,
          message: err instanceof Error ? err.message : String(err),
        });
      }
    }

    return jsonResponse({ claimed: rows.length, previewed, ambiguous, failed });
  }),
);

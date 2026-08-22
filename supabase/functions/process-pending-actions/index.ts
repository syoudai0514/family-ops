// verify_jwt=false — worker class. This worker has two safe phases:
// 1) convert sender-private draft LINE input into a structured pending action
//    and send a LINE preview (no business mutation yet), then
// 2) claim only explicitly confirmed pending actions and execute them.
import { createServiceRoleClient, requireWorkerToken } from '../_shared/auth.ts';
import { withServiceHandler, jsonResponse } from '../_shared/handler.ts';
import { buildPendingActionPreviewFlex } from '../_shared/lineMessageBuilders.ts';
import {
  daypartLabel,
  daypartToLocalTime,
  extractLineIntent,
  toTaskSubtasks,
} from '../process-line-inbox/lineIntent.ts';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

const WORKER_ID = `process-pending-actions:${crypto.randomUUID()}`;
const BATCH_LIMIT = Number(Deno.env.get('PENDING_ACTIONS_BATCH_LIMIT') ?? '25');
const LEASE_SECONDS = Number(Deno.env.get('PENDING_ACTIONS_LEASE_SECONDS') ?? '55');
const MAX_ATTEMPTS = Number(Deno.env.get('PENDING_ACTIONS_MAX_ATTEMPTS') ?? '5');
const RETRY_DELAY_SECONDS = Number(Deno.env.get('PENDING_ACTIONS_RETRY_DELAY_SECONDS') ?? '30');
const LINE_DRAFT_BATCH_LIMIT = Number(Deno.env.get('LINE_DRAFT_BATCH_LIMIT') ?? '20');

interface PendingActionItem {
  id: string;
  household_id: string;
  actor_id: string;
  action_type: string;
  normalized_payload: Record<string, unknown>;
  operation_id: string;
  attempts: number;
  lease_token: string;
}

type DraftRow = Pick<
  PendingActionItem,
  'id' | 'household_id' | 'actor_id' | 'action_type' | 'normalized_payload'
>;

type PreparedDraft = {
  actionType: 'shopping_item_add' | 'task_create_once' | 'request_create';
  payload: Record<string, unknown>;
  kindLabel: string;
  targetLabel: string;
};

interface ExecutionOutcome {
  result_type: string;
  result_id: string | null;
}

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
  const dateLabel = /^\d{4}-\d{2}-\d{2}$/.test(date)
    ? `${Number(date.slice(5, 7))}/${Number(date.slice(8, 10))}`
    : date || '今日';
  const part = time ?? (
    daypart && ['morning', 'noon', 'evening', 'night'].includes(daypart)
      ? daypartLabel(daypart as 'morning' | 'noon' | 'evening' | 'night')
      : '時刻なし'
  );
  return `${dateLabel} ${part}`;
}

function previewDetailLines(payload: Record<string, unknown>): string[] {
  const lines: string[] = [];
  if (typeof payload.context === 'string' && payload.context.trim()) {
    lines.push(`予定: ${payload.context.trim()}`);
  }
  if (Array.isArray(payload.subtasks)) {
    const subtasks = payload.subtasks
      .filter((item): item is string => typeof item === 'string' && item.trim().length > 0)
      .slice(0, 5)
      .map((item) => `・${item.trim()}`);
    if (subtasks.length > 0) lines.push('準備: ' + subtasks.join(' '));
  }
  return lines;
}

async function prepareDraft(client: SupabaseClient, row: DraftRow): Promise<PreparedDraft | null> {
  const original = { ...row.normalized_payload };

  // Inputs already handled by the old deterministic parser still get a LINE
  // preview now instead of requiring the PWA.
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
  const roleLabel =
    intent.targetRole === 'papa' ? 'パパ' : intent.targetRole === 'mama' ? 'ママ' : null;
  const dueLocalTime = intent.dueLocalTime ?? daypartToLocalTime(intent.daypart);

  if (intent.kind === 'shopping') {
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
        context: intent.context,
        target_label: roleLabel ?? '買い物リスト',
        parse_source: intent.source,
      },
      kindLabel: '買い物',
      targetLabel: roleLabel ?? '買い物リスト',
    };
  }

  const requestedRecipient =
    intent.kind === 'request'
      ? (roleUser ?? (await partnerUserId(client, row.household_id, row.actor_id)))
      : null;

  // Another person is always a request. Never silently assign a spouse task.
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
        context: intent.context,
        target_label: roleLabel ?? 'パートナー',
        parse_source: intent.source,
      },
      kindLabel: 'お願い',
      targetLabel: roleLabel ?? 'パートナー',
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
      planned_assignee_user_id: roleUser ?? row.actor_id,
      routine_phase: 'anytime',
      daypart: intent.daypart,
      subtasks: intent.subtasks,
      context: intent.context,
      target_label: roleLabel ?? '自分',
      parse_source: intent.source,
    },
    kindLabel: 'タスク',
    targetLabel: roleLabel ?? '自分',
  };
}

async function enqueueDraftPreview(
  client: SupabaseClient,
  row: DraftRow,
  prepared: PreparedDraft,
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
      detailLines: previewDetailLines(prepared.payload),
      confirmLabel: prepared.actionType === 'request_create' ? 'この内容で送る' : 'この内容で登録',
    }),
  });
  if (error) throw new Error(error.message);
}

async function enqueueClarification(client: SupabaseClient, row: DraftRow): Promise<void> {
  const { error } = await client.rpc('server_tx_enqueue_immediate_line_push', {
    p_household_id: row.household_id,
    p_recipient_user_id: row.actor_id,
    p_text:
      '予定にうまく変換できませんでした。「明日の朝、歯医者の予約をママにお願い」のように、いつ・何を・誰がを入れてもう一度送ってください。入力はアプリの判断待ちにも残しています。',
    p_dedup_key: `line-natural-clarify:${row.id}`,
    p_rich_message: null,
  });
  if (error) throw new Error(error.message);
}

async function processLineDrafts(
  client: SupabaseClient,
): Promise<{ previewed: number; ambiguous: number; failed: number }> {
  const { data, error } = await client.rpc('server_tx_claim_line_draft_batch', {
    p_limit: LINE_DRAFT_BATCH_LIMIT,
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
        const { error: markError } = await client.rpc('server_tx_mark_line_pending_parse_failed', {
          p_id: row.id,
        });
        if (markError) throw new Error(markError.message);
        ambiguous++;
        continue;
      }
      const { error: prepareError } = await client.rpc('server_tx_prepare_line_pending_preview', {
        p_id: row.id,
        p_action_type: prepared.actionType,
        p_normalized_payload: prepared.payload,
      });
      if (prepareError) throw new Error(prepareError.message);
      await enqueueDraftPreview(client, row, prepared);
      const { error: markError } = await client.rpc('server_tx_mark_line_pending_previewed', {
        p_id: row.id,
      });
      if (markError) throw new Error(markError.message);
      previewed++;
    } catch (err) {
      failed++;
      console.error('process-pending-actions: LINE draft failed', {
        id: row.id,
        message: err instanceof Error ? err.message : String(err),
      });
    }
  }
  return { previewed, ambiguous, failed };
}

function requestDueAt(payload: Record<string, unknown>): string | null {
  const date = typeof payload.scheduled_date === 'string' ? payload.scheduled_date : null;
  if (!date) return null;
  const localTime =
    typeof payload.due_local_time === 'string' && /^\d{2}:\d{2}$/.test(payload.due_local_time)
      ? payload.due_local_time
      : '23:59';
  const value = new Date(`${date}T${localTime}:00+09:00`);
  return Number.isNaN(value.getTime()) ? null : value.toISOString();
}

async function execute(client: SupabaseClient, item: PendingActionItem): Promise<ExecutionOutcome> {
  const p = item.normalized_payload;
  switch (item.action_type) {
    case 'shopping_item_add': {
      const { data, error } = await client.rpc('server_tx_add_shopping_item', {
        p_actor_id: item.actor_id,
        p_operation_id: item.operation_id,
        p_title: String(p.title ?? ''),
        p_purchase_method: String(p.purchase_method ?? 'store'),
        p_assignee_user_id: p.assignee_user_id ?? null,
        p_url: p.url ?? null,
        p_due_at: p.due_at ?? null,
      });
      if (error) throw new Error(error.message);
      return {
        result_type: 'shopping_item',
        result_id: (data as { shopping_item_id?: string })?.shopping_item_id ?? null,
      };
    }
    case 'task_create_once': {
      const subtasks = toTaskSubtasks(p.subtasks);
      const { data, error } = await client.rpc('server_tx_create_task', {
        p_actor_id: item.actor_id,
        p_operation_id: item.operation_id,
        p_title: String(p.title ?? ''),
        p_category: p.category ?? 'todo',
        p_scheduled_date: p.scheduled_date,
        p_due_local_time: p.due_local_time ?? null,
        p_planned_assignee_user_id: p.planned_assignee_user_id ?? null,
        p_completion_mode: subtasks ? 'subtasks' : 'whole',
        p_routine_phase: p.routine_phase ?? 'anytime',
        p_subtasks: subtasks,
      });
      if (error) throw new Error(error.message);
      return { result_type: 'task', result_id: (data as { task_id?: string })?.task_id ?? null };
    }
    case 'request_create': {
      const recipient = typeof p.recipient_user_id === 'string' ? p.recipient_user_id : '';
      if (!recipient) throw new Error('request_create missing recipient_user_id');
      const { data, error } = await client.rpc('server_tx_send_request', {
        p_actor_id: item.actor_id,
        p_operation_id: item.operation_id,
        p_recipient_user_id: recipient,
        p_shared_title: String(p.title ?? ''),
        p_shared_message: typeof p.shared_message === 'string' ? p.shared_message : null,
        p_due_at: requestDueAt(p),
      });
      if (error) throw new Error(error.message);
      return {
        result_type: 'request',
        result_id: (data as { request_id?: string })?.request_id ?? null,
      };
    }
    case 'request_accept': {
      const requestId = typeof p.request_id === 'string' ? p.request_id : '';
      if (!requestId) throw new Error('request_accept missing request_id');
      const { data, error } = await client.rpc('server_tx_accept_request', {
        p_actor_id: item.actor_id,
        p_operation_id: item.operation_id,
        p_request_id: requestId,
      });
      if (error) {
        if (/REQUEST_(?:NOT_PENDING|ACCEPT_NOT_ALLOWED)/.test(error.message))
          return { result_type: 'request', result_id: requestId };
        throw new Error(error.message);
      }
      return { result_type: 'task', result_id: (data as { task_id?: string })?.task_id ?? null };
    }
    case 'request_decline': {
      const requestId = typeof p.request_id === 'string' ? p.request_id : '';
      if (!requestId) throw new Error('request_decline missing request_id');
      const { data, error } = await client.rpc('server_tx_decline_request', {
        p_actor_id: item.actor_id,
        p_operation_id: item.operation_id,
        p_request_id: requestId,
      });
      if (error) {
        if (/REQUEST_(?:NOT_PENDING|DECLINE_NOT_ALLOWED)/.test(error.message))
          return { result_type: 'request', result_id: requestId };
        throw new Error(error.message);
      }
      return {
        result_type: 'request',
        result_id: (data as { request_id?: string })?.request_id ?? requestId,
      };
    }
    case 'assignment_change_request': {
      const { data, error } = await client.rpc('server_tx_create_assignment_change_request', {
        p_actor_id: item.actor_id,
        p_operation_id: item.operation_id,
        p_task_id: p.task_id,
        p_recipient_user_id: p.recipient_user_id,
        p_shared_message: p.shared_message ?? null,
        p_scope: p.scope ?? 'once',
      });
      if (error) throw new Error(error.message);
      return {
        result_type: 'request',
        result_id: (data as { request_id?: string })?.request_id ?? null,
      };
    }
    default:
      throw new Error(`unsupported action_type: ${item.action_type}`);
  }
}

Deno.serve(
  withServiceHandler(async (req: Request) => {
    requireWorkerToken(req);
    const client = createServiceRoleClient();

    const draftSummary = await processLineDrafts(client);

    const { data: batchData, error: claimError } = await client.rpc(
      'server_tx_claim_pending_actions_batch',
      {
        p_worker_id: WORKER_ID,
        p_limit: BATCH_LIMIT,
        p_lease_seconds: LEASE_SECONDS,
      },
    );
    if (claimError) throw new Error(claimError.message);

    const items = (batchData ?? []) as PendingActionItem[];
    let succeeded = 0;
    let failed = 0;
    for (const item of items) {
      try {
        const outcome = await execute(client, item);
        const { data: completeData } = await client.rpc('server_tx_complete_pending_action', {
          p_id: item.id,
          p_lease_token: item.lease_token,
          p_result_type: outcome.result_type,
          p_result_id: outcome.result_id,
        });
        if ((completeData as { ok?: boolean } | null)?.ok) succeeded++;
      } catch (err) {
        failed++;
        const message = err instanceof Error ? err.message : String(err);
        console.error('process-pending-actions: execution failed', { id: item.id, message });
        await client.rpc('server_tx_fail_pending_action', {
          p_id: item.id,
          p_lease_token: item.lease_token,
          p_error: message.slice(0, 500),
          p_max_attempts: MAX_ATTEMPTS,
          p_retry_delay_seconds: RETRY_DELAY_SECONDS,
        });
      }
    }

    return jsonResponse({
      drafts: draftSummary,
      confirmed: { claimed: items.length, succeeded, failed },
    });
  }),
);

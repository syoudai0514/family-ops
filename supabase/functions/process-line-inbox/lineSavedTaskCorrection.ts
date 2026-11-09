import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";

export type SavedTaskCorrectionContext = {
  client: SupabaseClient;
  actorId: string;
  householdId: string;
  eventId: string;
  reply: (text: string, quickReplies?: LineQuickReplyAction[]) => Promise<void>;
};

type SavedTask = {
  pending_action_id: string;
  task_id: string;
  household_id: string;
  title: string;
  scheduled_date: string;
  due_at: string | null;
  status: string;
  revision: number;
  can_reschedule: boolean;
  can_reopen: boolean;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;
const latest: LineQuickReplyAction = { type: "message", label: "今日を見る", text: "今日" };

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : null;
}

function savedTask(value: unknown, ctx: SavedTaskCorrectionContext, pendingId: string): SavedTask | null {
  const row = record(value);
  if (!row || row.pending_action_id !== pendingId || row.household_id !== ctx.householdId ||
    typeof row.task_id !== "string" || !UUID.test(row.task_id) ||
    typeof row.title !== "string" || !row.title.trim() ||
    typeof row.scheduled_date !== "string" || !/^\d{4}-\d{2}-\d{2}$/u.test(row.scheduled_date) ||
    !(row.due_at === null || typeof row.due_at === "string" && Number.isFinite(Date.parse(row.due_at))) ||
    !Number.isSafeInteger(row.revision) || Number(row.revision) < 1 ||
    typeof row.status !== "string" || typeof row.can_reschedule !== "boolean" || typeof row.can_reopen !== "boolean"
  ) return null;
  return row as SavedTask;
}

function fields(action: string, pendingId: string, revision?: number, due?: string): string {
  const values = new URLSearchParams({ action, pending_action_id: pendingId });
  if (revision !== undefined) values.set("revision", String(revision));
  if (due) values.set("due", new Date(Date.parse(due) + 9 * 3600_000).toISOString().slice(0, 16));
  return values.toString();
}

function postback(label: string, data: string): LineQuickReplyAction {
  return { type: "postback", label, displayText: label, data };
}

function subject(row: Pick<SavedTask, "title" | "scheduled_date" | "due_at">): string {
  const time = row.due_at ? new Intl.DateTimeFormat("ja-JP", {
    timeZone: "Asia/Tokyo", hour: "2-digit", minute: "2-digit", hour12: false,
  }).format(new Date(row.due_at)) : "時刻なし";
  return `${row.scheduled_date} ${time} ${row.title}`;
}

async function read(ctx: SavedTaskCorrectionContext, pendingId: string): Promise<SavedTask | null> {
  if (!UUID.test(pendingId)) return null;
  try {
    const { data, error } = await ctx.client.rpc("server_read_line_saved_task_v1", {
      p_actor_id: ctx.actorId, p_pending_action_id: pendingId,
    });
    return error ? null : savedTask(data, ctx, pendingId);
  } catch { return null; }
}

function unavailable(ctx: SavedTaskCorrectionContext): Promise<void> {
  return ctx.reply("登録先を安全に確認できないか、この内容はLINEでの最近の訂正の対象外です。新しい作業は作成していません。今日の一覧から対象を確認してください。", [latest]);
}

export async function openSavedTaskCorrection(ctx: SavedTaskCorrectionContext, pendingId: string): Promise<void> {
  const row = await read(ctx, pendingId);
  if (!row) return await unavailable(ctx);
  const quick: LineQuickReplyAction[] = [];
  if (row.can_reschedule) {
    quick.push({ type: "datetimepicker", label: "日時を変更", mode: "datetime",
      data: fields("lst_reschedule", pendingId, row.revision),
      ...(row.due_at ? { initial: new Date(Date.parse(row.due_at) + 9 * 3600_000).toISOString().slice(0, 16) } : {}),
    });
  }
  if (row.can_reopen) quick.push(postback("完了を取り消す", fields("lst_reopen_prompt", pendingId, row.revision)));
  quick.push(latest);
  await ctx.reply(`登録済みの内容\n${subject(row)}\n\n${
    quick.length > 1 ? "変更する操作を選んでください。下書きの取消では、登録済みの作業は消しません。" :
      "この状態はLINEでの日時変更・完了取消の対象外です。チェック項目や詳しい編集は今日の一覧で確認してください。"
  }`, quick);
}

/** A picker result is a local JST minute, not an untrusted ISO timestamp. */
export function parseSavedTaskDatetime(value: string | undefined): string | null {
  if (!value || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/u.test(value)) return null;
  const date = new Date(`${value}:00+09:00`);
  if (!Number.isFinite(date.getTime()) ||
    new Date(date.getTime() + 9 * 3600_000).toISOString().slice(0, 16) !== value) return null;
  return date.toISOString();
}

async function operationId(ctx: SavedTaskCorrectionContext, pendingId: string, revision: number, action: string, due: string | null): Promise<string> {
  // Same displayed button retries the same operation, including after a reply
  // was lost. Event IDs must not turn a retry into a second write.
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(
    ["line-saved-correction", ctx.actorId, ctx.householdId, pendingId, String(revision), action, due ?? ""].join("|"),
  ))).slice(0, 16);
  hash[6] = (hash[6] & 15) | 64;
  hash[8] = (hash[8] & 63) | 128;
  const hex = [...hash].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export async function tryHandleSavedTaskCorrectionPostback(ctx: SavedTaskCorrectionContext, input: Record<string, string>): Promise<boolean> {
  if (!input.action?.startsWith("lst_")) return false;
  const pendingId = input.pending_action_id ?? "";
  if (input.action === "lst_open") { await openSavedTaskCorrection(ctx, pendingId); return true; }
  const revision = Number(input.revision);
  if (!UUID.test(pendingId) || !/^\d+$/u.test(input.revision ?? "") || !Number.isSafeInteger(revision) || revision < 1) {
    await unavailable(ctx); return true;
  }
  if (input.action === "lst_reschedule" || input.action === "lst_reopen_prompt") {
    const row = await read(ctx, pendingId);
    if (!row) { await unavailable(ctx); return true; }
    if (row.revision !== revision) {
      await ctx.reply("内容が更新されています。最新の内容から操作を選び直してください。", [postback("最新を開く", fields("lst_open", pendingId))]);
      return true;
    }
    const due = input.action === "lst_reschedule" ? parseSavedTaskDatetime(input.datetime) : null;
    if (input.action === "lst_reschedule" && (!row.can_reschedule || !due) || input.action === "lst_reopen_prompt" && !row.can_reopen) {
      await unavailable(ctx); return true;
    }
    await ctx.reply(input.action === "lst_reschedule"
      ? `日時を変更しますか？\n現在: ${subject(row)}\n変更後: ${new Intl.DateTimeFormat("ja-JP", { timeZone: "Asia/Tokyo", dateStyle: "medium", timeStyle: "short" }).format(new Date(due!))}\nまだ変更していません。`
      : `この完了を取り消して未完了に戻しますか？\n${subject(row)}\n完了の履歴は残ります。`, [
      postback(input.action === "lst_reschedule" ? "この日時に変更" : "未完了に戻す",
        fields(input.action === "lst_reschedule" ? "lst_apply" : "lst_reopen", pendingId, revision, due ?? undefined)),
      postback("戻る", fields("lst_open", pendingId)),
    ]);
    return true;
  }
  if (input.action !== "lst_apply" && input.action !== "lst_reopen") { await unavailable(ctx); return true; }
  const action = input.action === "lst_apply" ? "reschedule" : "reopen";
  const due = action === "reschedule" ? parseSavedTaskDatetime(input.due) : null;
  if (action === "reschedule" && !due) { await unavailable(ctx); return true; }
  const id = await operationId(ctx, pendingId, revision, action, due);
  try {
    const { data, error } = await ctx.client.rpc("server_tx_correct_line_saved_task_v1", {
      p_actor_id: ctx.actorId, p_operation_id: id, p_pending_action_id: pendingId,
      p_expected_revision: revision, p_action: action, p_new_due_at: due,
    });
    if (error) {
      if (/REVISION|STALE|NOT_CORRECTABLE|NEEDS_DETAIL|INVALID_INPUT/u.test(error.message ?? "")) {
        await ctx.reply("内容が変わっているか、この日時への変更をLINEでは確定できません。最新の内容から選び直してください。", [postback("最新を開く", fields("lst_open", pendingId)), latest]);
      } else {
        await ctx.reply("保存結果を確認できません。同じ操作で結果を確認してください。", [postback("結果を確認", fields(input.action, pendingId, revision, due ?? undefined))]);
      }
      return true;
    }
    const result = record(data);
    if (result?.ok !== true || result.household_id !== ctx.householdId || result.pending_action_id !== pendingId ||
      result.action !== action || typeof result.task_id !== "string" || !UUID.test(result.task_id) ||
      !Number.isSafeInteger(result.revision) || Number(result.revision) <= revision ||
      (action === "reopen" && result.status !== "todo") ||
      (action === "reschedule" && (typeof result.due_at !== "string" || Date.parse(result.due_at) !== Date.parse(due!))) ||
      typeof result.title !== "string" || typeof result.scheduled_date !== "string" ||
      !(result.due_at === null || typeof result.due_at === "string" && Number.isFinite(Date.parse(result.due_at)))) {
      await ctx.reply("保存結果を確認できません。同じ操作で結果を確認してください。", [postback("結果を確認", fields(input.action, pendingId, revision, due ?? undefined))]);
      return true;
    }
    await ctx.reply(`✓ ${action === "reschedule" ? "日時を変更しました" : "完了を取り消しました（未完了）"}\n${subject(result as unknown as SavedTask)}`, [postback("直す・最新を見る", fields("lst_open", pendingId)), latest]);
  } catch {
    await ctx.reply("保存結果を確認できません。同じ操作で結果を確認してください。", [postback("結果を確認", fields(input.action, pendingId, revision, due ?? undefined))]);
  }
  return true;
}

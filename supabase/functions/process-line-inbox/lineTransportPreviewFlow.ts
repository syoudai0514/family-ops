import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";
import { parseTransportAgreementFollowUp } from "./lineTransportAgreement.ts";

type Context = {
  client: SupabaseClient;
  actorId: string;
  householdId: string;
  eventId: string;
  reply: (text: string, quickReplies?: LineQuickReplyAction[]) => Promise<void>;
};

type Preview = {
  id: string;
  status: string;
  household_id: string;
  actor_id: string;
  task_id: string;
  scheduled_date: string;
  due_at: string | null;
  title: string;
  code: "dropoff" | "pickup";
  current_assignee_user_id: string | null;
  assignee_user_id: string;
  current_label: string;
  target_label: string;
  expected_revision: number;
  expires_at: string;
  result?: unknown;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;
const MISSING_TARGET =
  "確認済みという申告だけでは、変更する送迎を確認できませんでした。担当は変更していません。「今日の送りを私に変更」のように、日付・送りかお迎え・変更後の担当をもう一度送ってください。";

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function validDate(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/u.test(value)) {
    return false;
  }
  const date = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(date.getTime()) &&
    date.toISOString().slice(0, 10) === value;
}

function preview(value: unknown, ctx: Context): Preview | null {
  const row = record(value);
  if (
    !row || row.actor_id !== ctx.actorId ||
    row.household_id !== ctx.householdId ||
    ![row.id, row.task_id, row.assignee_user_id].every((id) =>
      typeof id === "string" && UUID.test(id)
    ) ||
    !(row.current_assignee_user_id === null ||
      typeof row.current_assignee_user_id === "string" &&
        UUID.test(row.current_assignee_user_id)) ||
    !validDate(row.scheduled_date) ||
    !["dropoff", "pickup"].includes(String(row.code)) ||
    typeof row.status !== "string" || typeof row.title !== "string" ||
    typeof row.current_label !== "string" || !row.current_label.trim() ||
    typeof row.target_label !== "string" || !row.target_label.trim() ||
    !(row.due_at === null ||
      typeof row.due_at === "string" &&
        Number.isFinite(Date.parse(row.due_at))) ||
    typeof row.expected_revision !== "number" ||
    !Number.isSafeInteger(row.expected_revision) || row.expected_revision < 0 ||
    typeof row.expires_at !== "string" ||
    !Number.isFinite(Date.parse(row.expires_at))
  ) return null;
  return row as Preview;
}

async function rpc(ctx: Context, name: string, args: Record<string, unknown>) {
  try {
    const { data, error } = await ctx.client.rpc(name, args);
    return { data, error: error?.message ?? null };
  } catch {
    return { data: null, error: "READ_OR_RESULT_UNAVAILABLE" };
  }
}

async function operationId(ctx: Context): Promise<string> {
  const hash = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(
        ["line-transport-preview", ctx.householdId, ctx.actorId, ctx.eventId]
          .join("|"),
      ),
    ),
  );
  const bytes = hash.slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${
    hex.slice(16, 20)
  }-${hex.slice(20)}`;
}

function subject(row: Preview): string {
  const day = new Date(`${row.scheduled_date}T00:00:00Z`);
  const date = `${day.getUTCMonth() + 1}/${day.getUTCDate()}(${
    "日月火水木金土"[day.getUTCDay()]
  })`;
  const time = row.due_at
    ? ` ${
      new Intl.DateTimeFormat("ja-JP", {
        timeZone: "Asia/Tokyo",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
      }).format(new Date(row.due_at))
    }`
    : "";
  return `${date}${time} ${row.code === "dropoff" ? "送り" : "お迎え"}`;
}

function confirmationText(row: Preview): string {
  return `担当変更の確認\n${
    subject(row)
  }\n現在: ${row.current_label} → 変更後: ${row.target_label}\n適用範囲: 今回だけ\n\n担当はまだ変更していません。\n2人で話し合い済みなら、下の「2人で調整済み・変更する」を押してください。その日の送迎担当と、連動する未完了の家事を変更します。いつもの曜日ルールや他の日は変わりません。\nまだ話し合っていない場合は、先に相手と調整してください。`;
}

function notAgreedText(row: Preview): string {
  return `担当変更の確認\n${
    subject(row)
  }\n現在: ${row.current_label} → 変更後: ${row.target_label}\n適用範囲: 今回だけ\n\n担当は変更していません。先に相手と調整してください。話し合いが済んだら「話し合い済み」と送って、確認ボタンで変更できます。`;
}

function actions(row: Preview): LineQuickReplyAction[] {
  const postback = (label: string, action: string): LineQuickReplyAction => ({
    type: "postback",
    label,
    displayText: label,
    data: new URLSearchParams({ action, preview_id: row.id }).toString(),
  });
  return [
    postback("2人で調整済み・変更する", "lt_agreed_confirm"),
    postback("やめる", "lt_cancel"),
  ];
}

function isFresh(row: Preview): boolean {
  return row.status === "draft" && Date.parse(row.expires_at) > Date.now();
}

function isSucceeded(row: Preview): boolean {
  const result = record(row.result);
  return row.status === "succeeded" && result?.task_id === row.task_id &&
    typeof result.revision === "number" &&
    Number.isSafeInteger(result.revision) &&
    result.revision > row.expected_revision;
}

function successText(row: Preview): string {
  return `✓ 担当を変更しました\n${
    subject(row)
  }\n${row.current_label} → ${row.target_label}\n今回だけ・2人で調整済みとして登録しました。連動する当日の家事も更新しました。`;
}

function staleMessage(code: string | null): string {
  if (/NOT_ACTIONABLE|SUCCEEDED|CANCELLED/u.test(code ?? "")) {
    return "この担当変更の確認はすでに処理済みです。最新の担当を確認してください。";
  }
  if (/EXPIRED/u.test(code ?? "")) {
    return "この担当変更の確認は期限切れです。担当は変更していません。日付と変更後の担当をもう一度送ってください。";
  }
  if (
    /STALE|REVISION|CONFLICT|SUPERSEDED|TASK_NOT_OPEN|TASK_TERMINAL/u.test(
      code ?? "",
    )
  ) {
    return "予定が変わったため、この確認からは担当を変更できません。最新の日付と変更後の担当をもう一度送ってください。";
  }
  return "この担当変更の確認を読み込めませんでした。担当は変更していません。日付と変更後の担当をもう一度送ってください。";
}

export async function openLineTransportPreview(
  ctx: Context,
  input: {
    kind?: "review";
    taskId: string;
    assigneeUserId: string;
    expectedRevision: number;
  },
): Promise<void> {
  const response = await rpc(
    ctx,
    "server_tx_prepare_line_transport_assignment_v1",
    {
      p_actor_id: ctx.actorId,
      p_operation_id: await operationId(ctx),
      p_task_id: input.taskId,
      p_assignee_user_id: input.assigneeUserId,
      p_expected_revision: input.expectedRevision,
    },
  );
  const row = preview(response.data, ctx);
  if (
    response.error || !row || row.task_id !== input.taskId ||
    row.assignee_user_id !== input.assigneeUserId ||
    row.expected_revision !== input.expectedRevision
  ) {
    await ctx.reply(staleMessage(response.error));
    return;
  }
  if (row.status === "succeeded") {
    await ctx.reply(
      isSucceeded(row) ? successText(row) : staleMessage("SUCCEEDED"),
    );
    return;
  }
  if (!isFresh(row)) {
    await ctx.reply(
      staleMessage(
        row.status === "draft" ? "EXPIRED" : row.status.toUpperCase(),
      ),
    );
    return;
  }
  await ctx.reply(confirmationText(row), actions(row));
}

function recentAssistant(
  turns: Array<Record<string, unknown> | null>,
): Record<string, unknown> | null {
  const lastAssistant = turns.findLastIndex((turn) =>
    turn?.role === "assistant"
  );
  const assistant = turns[lastAssistant];
  if (
    !assistant || typeof assistant.text !== "string" ||
    typeof assistant.at !== "string"
  ) return null;
  const at = Date.parse(assistant.at);
  if (
    !Number.isFinite(at) || at < Date.now() - 15 * 60_000 ||
    at > Date.now() + 60_000
  ) return null;
  if (
    !turns.slice(lastAssistant + 1).every((turn) =>
      turn?.role === "user" &&
      typeof turn.text === "string" &&
      parseTransportAgreementFollowUp(turn.text) !== null
    )
  ) return null;
  return assistant;
}

export async function handleLineTransportPreviewText(
  ctx: Context,
  text: string,
): Promise<boolean> {
  const followUp = parseTransportAgreementFollowUp(text);
  if (!followUp) return false;
  const response = await rpc(
    ctx,
    "server_read_line_transport_assignment_preview_v1",
    { p_actor_id: ctx.actorId },
  );
  const row = preview(response.data, ctx);
  const history = await rpc(ctx, "server_read_line_turns", {
    p_actor_id: ctx.actorId,
    p_limit: 4,
    p_within: "15 minutes",
  });
  if (history.error || !Array.isArray(history.data)) {
    await ctx.reply(MISSING_TARGET);
    return true;
  }
  const assistant = recentAssistant(history.data.map(record));
  const previous = typeof assistant?.text === "string" ? assistant.text : "";
  const nativeContext = previous.startsWith("担当変更の確認");
  const oldContext = previous.includes("現在:") &&
    previous.includes("変更希望:") &&
    previous.includes("担当はまだ変更していません");
  if (!nativeContext && !oldContext) return false;
  if (
    response.error || !row || !nativeContext ||
    ![confirmationText(row), notAgreedText(row)].includes(previous)
  ) {
    await ctx.reply(MISSING_TARGET);
    return true;
  }
  // The previous final tap may have committed while its reply was lost. A
  // text follow-up may read that receipt, but never executes another decision.
  if (isSucceeded(row)) {
    await ctx.reply(successText(row));
    return true;
  }
  if (!isFresh(row)) {
    await ctx.reply(
      staleMessage(
        row.status === "draft" ? "EXPIRED" : row.status.toUpperCase(),
      ),
    );
    return true;
  }
  if (followUp.kind === "not_agreed") {
    await ctx.reply(
      notAgreedText(row),
      actions(row).filter((action) =>
        action.type === "postback" && action.data.includes("lt_cancel")
      ),
    );
    return true;
  }
  await ctx.reply(confirmationText(row), actions(row));
  return true;
}

export async function handleLineTransportPreviewPostback(
  ctx: Context,
  fields: Record<string, string>,
): Promise<boolean> {
  if (!["lt_agreed_confirm", "lt_cancel"].includes(fields.action)) return false;
  if (!fields.preview_id || !UUID.test(fields.preview_id)) {
    await ctx.reply(
      "担当変更の確認を特定できませんでした。日付と変更後の担当をもう一度送ってください。",
    );
    return true;
  }
  const action = fields.action === "lt_agreed_confirm"
    ? "confirm_agreed"
    : "cancel";
  const response = await rpc(
    ctx,
    "server_tx_decide_line_transport_assignment_v1",
    {
      p_actor_id: ctx.actorId,
      p_preview_id: fields.preview_id,
      p_action: action,
    },
  );
  if (response.error) {
    const knownRejection =
      /LINE_TRANSPORT_PREVIEW_|AGGREGATE_REVISION_CONFLICT|TASK_NOT_OPEN|ACTOR_SCOPE|NOT_HOUSEHOLD_MEMBER/u
        .test(response.error);
    await ctx.reply(
      knownRejection
        ? staleMessage(response.error)
        : "変更結果を確認できませんでした。同じ確認ボタンでもう一度、結果を確認してください。新しい依頼は作っていません。",
    );
    return true;
  }
  const row = preview(response.data, ctx);
  if (!row || row.id !== fields.preview_id) {
    await ctx.reply(
      "変更結果を確認できませんでした。同じ確認ボタンでもう一度、結果を確認してください。",
    );
    return true;
  }
  if (action === "cancel" && row.status === "cancelled") {
    await ctx.reply("担当変更の確認を取り消しました。担当は変更していません。");
    return true;
  }
  if (action === "confirm_agreed" && isSucceeded(row)) {
    await ctx.reply(successText(row));
    return true;
  }
  await ctx.reply(
    "この確認はすでに状態が変わっています。最新の予定を確認してください。",
  );
  return true;
}

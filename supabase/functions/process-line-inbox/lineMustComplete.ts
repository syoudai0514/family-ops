import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";
import {
  buildItemPromptText,
  buildItemQuickReply,
  pickNextUnfinished,
  type RoutineSessionItem,
} from "./routineItemFlow.ts";
import {
  handleHandoverAckPostback,
  isHandoverReviewText,
  openHandoverReview,
} from "./lineHandoverFlow.ts";

export interface LineMustCompleteContext {
  client: SupabaseClient;
  actorId: string;
  householdId: string;
  eventId: string;
  reply: (text: string, quickReplies?: LineQuickReplyAction[]) => Promise<void>;
}

type JsonObject = Record<string, unknown>;

type RoutineSessionRead = {
  session_id: string;
  session_type?: string | null;
  status?: string | null;
  can_act?: boolean;
  current_session_id?: string | null;
  items?: RoutineSessionItem[];
};

type RequestView = {
  id: string;
  request_kind: string;
  shared_title: string;
  due_at: string | null;
  requester_actor_ref_id: string;
  recipient_actor_ref_id: string;
  revision: number;
};

type AttemptView = {
  id: string;
  request_id: string;
  state: string;
  revision: number;
  terms_revision: number;
  reply_due_at: string | null;
  terms: JsonObject;
  created_at: string;
};

function record(value: unknown): JsonObject | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as JsonObject
    : null;
}

function records(value: unknown): JsonObject[] {
  if (Array.isArray(value)) return value.map(record).filter((v): v is JsonObject => Boolean(v));
  const root = record(value);
  if (!root) return [];
  for (const key of ["sessions", "active", "items", "requests", "tasks"]) {
    if (Array.isArray(root[key])) return records(root[key]);
  }
  return [];
}

function str(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function num(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function postback(label: string, data: string, displayText = label): LineQuickReplyAction {
  return { type: "postback", label, data, displayText };
}

function message(label: string, text = label): LineQuickReplyAction {
  return { type: "message", label, text };
}

function encodeFields(action: string, fields: Record<string, string | number | null | undefined>): string {
  const params = new URLSearchParams({ action });
  for (const [key, value] of Object.entries(fields)) {
    if (value !== null && value !== undefined) params.set(key, String(value));
  }
  return params.toString();
}

async function deterministicOperationId(scope: string, ...parts: string[]): Promise<string> {
  const input = new TextEncoder().encode([scope, ...parts].join("|"));
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", input));
  const bytes = digest.slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function errorCode(error: { message?: string } | null): string {
  return error?.message ?? "UNKNOWN";
}

async function replyMutationError(ctx: LineMustCompleteContext, error: { message?: string } | null): Promise<void> {
  const code = errorCode(error);
  if (/STALE|REVISION|CONFLICT|NOT_ACTIONABLE|TERMINAL/.test(code)) {
    await ctx.reply("この操作は古くなっています。最新の状態をLINEで開き直して、もう一度選んでください。");
    return;
  }
  if (/EXPIRED/.test(code)) {
    await ctx.reply("返事期限を過ぎています。依頼した側からLINEで再提案してください。");
    return;
  }
  console.error("process-line-inbox: LINE must-complete mutation failed", code);
  await ctx.reply("更新できませんでした。状態は変更していません。LINEで最新の状態を開き直してください。");
}

function formatJst(value: string | null): string {
  if (!value) return "未設定";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("ja-JP", {
    timeZone: "Asia/Tokyo",
    month: "numeric",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(date);
}

export function parseStructuredWorkDue(text: string): string | null {
  const normalized = text.normalize("NFKC").trim();
  const match = normalized.match(/^条件期限\s+(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})$/u);
  if (!match) return null;
  const [, year, month, day, hour, minute] = match;
  const iso = `${year}-${month}-${day}T${hour}:${minute}:00+09:00`;
  const parsed = new Date(iso);
  if (Number.isNaN(parsed.getTime())) return null;
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(parsed);
  const value = Object.fromEntries(parts.map((p) => [p.type, p.value]));
  if (value.year !== year || value.month !== month || value.day !== day || value.hour !== hour || value.minute !== minute) return null;
  return parsed.toISOString();
}

function isDailyInputText(text: string): boolean {
  return /^(入力|家事入力|朝の入力|お迎えの入力|今夜の入力|今日の入力)$/u.test(text.normalize("NFKC").trim());
}

function isWaitingText(text: string): boolean {
  return /^(待ち|待ちにする|待ち一覧|再開するもの|次の確認)$/u.test(text.normalize("NFKC").trim());
}

function isShoppingText(text: string): boolean {
  return /^(買い物担当|買い物の担当|誰でもOK|誰でもOKの買い物)$/u.test(text.normalize("NFKC").trim());
}

function isRequestText(text: string): boolean {
  return /^(お願いの返事|お願い確認|返事|相談中|相談を確認)$/u.test(text.normalize("NFKC").trim());
}

function isSimulationText(text: string): boolean {
  return /^(1人テスト|一人テスト|テストモード|テスト状態)$/u.test(text.normalize("NFKC").trim());
}

async function openReconciliation(ctx: LineMustCompleteContext): Promise<void> {
  const { data, error } = await ctx.client.rpc("server_read_current_routine_sessions", { p_actor_id: ctx.actorId });
  if (error) {
    await replyMutationError(ctx, error);
    return;
  }
  const sessions = records(data)
    .map((row): RoutineSessionRead | null => {
      const id = str(row.session_id ?? row.id);
      if (!id) return null;
      return {
        session_id: id,
        session_type: str(row.session_type),
        status: str(row.status),
        can_act: typeof row.can_act === "boolean" ? row.can_act : row.status === "open",
        current_session_id: str(row.current_session_id),
      };
    })
    .filter((v): v is RoutineSessionRead => Boolean(v))
    .filter((v) => v.can_act !== false && v.status !== "submitted");
  const session = sessions[0];
  if (!session) {
    await ctx.reply("いま回答できる家事チェックはありません。今日の内容は「今日」で確認できます。");
    return;
  }
  const quick = [
    postback("全部やった", encodeFields("mc_reconcile", { session_id: session.session_id, response_kind: "all_done" })),
    postback("大体やった", encodeFields("mc_reconcile", { session_id: session.session_id, response_kind: "mostly_done" })),
    postback("個別で答える", encodeFields("mc_reconcile", { session_id: session.session_id, response_kind: "individual" })),
  ];
  await ctx.reply("今日の家事、どうでしたか？ LINEの中だけで回答できます。", quick);
}

async function individualRoutinePrompt(ctx: LineMustCompleteContext, sessionId: string): Promise<void> {
  const { data, error } = await ctx.client.rpc("server_tx_get_routine_session", {
    p_actor_id: ctx.actorId,
    p_session_id: sessionId,
  });
  if (error) {
    await replyMutationError(ctx, error);
    return;
  }
  const root = record(data);
  const items = records(root?.items ?? []).map((row): RoutineSessionItem | null => {
    const id = str(row.task_instance_id ?? row.id);
    const title = str(row.title);
    if (!id || !title) return null;
    return {
      task_instance_id: id,
      title,
      status: str(row.status) ?? "todo",
      outcome: str(row.outcome),
    } as RoutineSessionItem;
  }).filter((v): v is RoutineSessionItem => Boolean(v));
  const next = pickNextUnfinished(items, null);
  if (!next) {
    await ctx.reply("✓ 回答する項目はありません。");
    return;
  }
  await ctx.reply(buildItemPromptText(sessionId, next), buildItemQuickReply(sessionId, next.task_instance_id));
}

async function reconcile(ctx: LineMustCompleteContext, fields: Record<string, string>): Promise<void> {
  const sessionId = fields.session_id;
  const responseKind = fields.response_kind;
  if (!sessionId || !["all_done", "mostly_done", "individual"].includes(responseKind)) return;
  const operationId = await deterministicOperationId("line-reconcile", ctx.eventId, sessionId, responseKind);
  const { data, error } = await ctx.client.rpc("server_tx_reconcile_routine_session_v2", {
    p_actor_id: ctx.actorId,
    p_operation_id: operationId,
    p_session_id: sessionId,
    p_response_kind: responseKind,
  });
  if (error) {
    await replyMutationError(ctx, error);
    return;
  }
  if (responseKind === "individual") {
    await individualRoutinePrompt(ctx, sessionId);
    return;
  }
  const root = record(data);
  const reconciliationId = str(root?.reconciliation_operation_id) ?? operationId;
  const label = responseKind === "all_done" ? "✓ 全部やった、で記録しました。" : "✓ 大体やった、で記録しました。必要なら個別に続けられます。";
  const quick: LineQuickReplyAction[] = [];
  if (responseKind === "all_done") {
    quick.push(postback("元に戻す", encodeFields("mc_reconcile_undo", { target_operation_id: reconciliationId }), "さっきの入力を元に戻す"));
  }
  quick.push(message("個別で確認", "入力"));
  await ctx.reply(label, quick);
}

async function undoReconciliation(ctx: LineMustCompleteContext, targetOperationId: string): Promise<void> {
  const operationId = await deterministicOperationId("line-reconcile-undo", ctx.eventId, targetOperationId);
  const { error } = await ctx.client.rpc("server_tx_undo_routine_reconciliation", {
    p_actor_id: ctx.actorId,
    p_operation_id: operationId,
    p_target_operation_id: targetOperationId,
  });
  if (error) {
    await replyMutationError(ctx, error);
    return;
  }
  await ctx.reply("✓ さっきの「全部やった」を元に戻しました。最新状態から入力し直せます。", [message("入力し直す", "入力")]);
}

async function openWaiting(ctx: LineMustCompleteContext): Promise<void> {
  const { data, error } = await ctx.client.from("task_instances")
    .select("id,title,revision,attention_state,next_check_at,status")
    .eq("household_id", ctx.householdId)
    .in("status", ["todo", "in_progress"])
    .order("due_at", { ascending: true, nullsFirst: false })
    .limit(8);
  if (error) {
    await replyMutationError(ctx, error);
    return;
  }
  const rows = records(data);
  if (rows.length === 0) {
    await ctx.reply("いま「待ち」にできる未完了タスクはありません。");
    return;
  }
  const quick = rows.slice(0, 4).flatMap((row) => {
    const id = str(row.id) ?? "";
    const revision = num(row.revision) ?? 1;
    const waiting = row.attention_state === "waiting";
    const title = (str(row.title) ?? "タスク").slice(0, 10);
    if (!waiting) return [postback(`待ち・${title}`, encodeFields("mc_wait_select", { task_id: id, revision }))];
    return [
      postback(`再開・${title}`, encodeFields("mc_wait_resume", { task_id: id, revision })),
      postback(`確認日・${title}`, encodeFields("mc_wait_update", { task_id: id, revision })),
    ];
  });
  await ctx.reply("待ち状態を変えるタスクを選んでください。変更時は、この画面で見た版だけを更新します。", quick);
}

async function setWaiting(ctx: LineMustCompleteContext, fields: Record<string, string>, action: "set" | "update" | "resume"): Promise<void> {
  const taskId = fields.task_id;
  const revision = Number(fields.revision);
  if (!taskId || !Number.isFinite(revision)) return;
  if ((action === "set" || action === "update") && !fields.next_check) {
    const nextAction = action === "update" ? "mc_wait_update" : "mc_wait_set";
    await ctx.reply(action === "update" ? "次の確認日を変更します。" : "次に確認するタイミングを選べます。", [
      postback("明日確認", encodeFields(nextAction, { task_id: taskId, revision, next_check: "tomorrow" })),
      postback("3日後確認", encodeFields(nextAction, { task_id: taskId, revision, next_check: "3days" })),
      postback("時刻なし", encodeFields(nextAction, { task_id: taskId, revision, next_check: "none" })),
    ]);
    return;
  }
  const nextCheckAt = fields.next_check === "none" || action === "resume"
    ? null
    : (() => {
      const days = fields.next_check === "3days" ? 3 : 1;
      const now = new Date();
      const jstDate = new Date(now.getTime() + 9 * 60 * 60 * 1000);
      jstDate.setUTCDate(jstDate.getUTCDate() + days);
      jstDate.setUTCHours(0, 0, 0, 0);
      return new Date(jstDate.getTime() - 9 * 60 * 60 * 1000 + 9 * 60 * 60 * 1000).toISOString();
    })();
  const operationId = await deterministicOperationId("line-waiting", ctx.eventId, taskId, action, fields.next_check ?? "");
  const { data, error } = await ctx.client.rpc("server_tx_set_task_waiting", {
    p_actor_id: ctx.actorId,
    p_operation_id: operationId,
    p_task_id: taskId,
    p_expected_revision: revision,
    p_waiting_action: action,
    p_waiting_note: action === "resume" ? null : "LINEから待ちに設定",
    p_next_check_at: nextCheckAt,
    p_source: "line",
  });
  if (error) {
    await replyMutationError(ctx, error);
    return;
  }
  const root = record(data);
  const newRevision = num(root?.revision);
  if (action === "resume") {
    await ctx.reply("✓ 待ちを解除して再開しました。");
  } else {
    await ctx.reply(`✓ 待ちにしました。次の確認: ${formatJst(nextCheckAt)}${newRevision ? `（版${newRevision}）` : ""}`);
  }
}

async function openShopping(ctx: LineMustCompleteContext): Promise<void> {
  const { data, error } = await ctx.client.rpc("server_read_shopping_workspace", { p_actor_id: ctx.actorId });
  if (error) {
    await replyMutationError(ctx, error);
    return;
  }
  const root = record(data);
  const selfActorRef = str(root?.actor_ref_id);
  const rows = records(root?.active ?? data).filter((row) => row.assignment_mode === "anyone");
  if (rows.length === 0) {
    await ctx.reply("いま担当を選べる「誰でもOK」の買い物はありません。");
    return;
  }
  const quick = rows.slice(0, 8).map((row) => {
    const id = str(row.shopping_item_id ?? row.id) ?? "";
    const revision = num(row.revision) ?? 1;
    const claimant = str(row.active_claimant_actor_ref_id);
    const action = !claimant ? "claim" : claimant === selfActorRef ? "release" : "takeover";
    const prefix = action === "claim" ? "担当する" : action === "release" ? "手放す" : "引き継ぐ";
    return postback(`${prefix}・${(str(row.title) ?? "買い物").slice(0, 11)}`, encodeFields("mc_shopping", {
      shopping_item_id: id,
      revision,
      claim_action: action,
    }));
  });
  await ctx.reply("「誰でもOK」の買い物です。担当する／手放すは割当ルールを書き換えず、現在の担当表明だけを更新します。", quick);
}

async function mutateShopping(ctx: LineMustCompleteContext, fields: Record<string, string>): Promise<void> {
  const id = fields.shopping_item_id;
  const revision = Number(fields.revision);
  const claimAction = fields.claim_action;
  if (!id || !Number.isFinite(revision) || !["claim", "release", "takeover"].includes(claimAction)) return;
  const operationId = await deterministicOperationId("line-shopping", ctx.eventId, id, claimAction);
  const { error } = await ctx.client.rpc("server_tx_shopping_claim_v2", {
    p_actor_id: ctx.actorId,
    p_operation_id: operationId,
    p_shopping_item_id: id,
    p_action: claimAction,
    p_expected_revision: revision,
  });
  if (error) {
    await replyMutationError(ctx, error);
    return;
  }
  const label = claimAction === "claim" ? "✓ 担当します、と記録しました。" : claimAction === "release" ? "✓ 担当を手放しました。" : "✓ 担当を引き継ぎました。";
  await ctx.reply(label, [message("買い物担当を確認", "買い物担当")]);
}

async function actorRefId(ctx: LineMustCompleteContext): Promise<string | null> {
  const { data } = await ctx.client.from("domain_actor_refs")
    .select("id")
    .eq("household_id", ctx.householdId)
    .eq("actor_kind", "real_user")
    .eq("real_user_id", ctx.actorId)
    .is("test_context_id", null)
    .maybeSingle();
  return str(record(data)?.id);
}

async function activeRequests(ctx: LineMustCompleteContext, includeExpired = false): Promise<Array<{ request: RequestView; attempt: AttemptView; party: "requester" | "recipient" }>> {
  const selfActorRef = await actorRefId(ctx);
  if (!selfActorRef) return [];
  const { data: requestData, error: requestError } = await ctx.client.from("requests")
    .select("id,request_kind,shared_title,due_at,requester_actor_ref_id,recipient_actor_ref_id,revision,created_at")
    .eq("household_id", ctx.householdId)
    .or(`requester_actor_ref_id.eq.${selfActorRef},recipient_actor_ref_id.eq.${selfActorRef}`)
    .order("created_at", { ascending: false })
    .limit(12);
  if (requestError) return [];
  const requestRows = records(requestData);
  const ids = requestRows.map((row) => str(row.id)).filter((v): v is string => Boolean(v));
  if (ids.length === 0) return [];
  const states = includeExpired
    ? ["pending", "checking", "consulting", "awaiting_confirmation", "expired"]
    : ["pending", "checking", "consulting", "awaiting_confirmation"];
  const { data: attemptData, error: attemptError } = await ctx.client.from("request_attempts")
    .select("id,request_id,state,revision,terms_revision,terms,reply_due_at,created_at")
    .in("request_id", ids)
    .in("state", states)
    .order("created_at", { ascending: false });
  if (attemptError) return [];
  const latest = new Map<string, JsonObject>();
  for (const row of records(attemptData)) {
    const requestId = str(row.request_id);
    if (requestId && !latest.has(requestId)) latest.set(requestId, row);
  }
  const result: Array<{ request: RequestView; attempt: AttemptView; party: "requester" | "recipient" }> = [];
  for (const row of requestRows) {
    const id = str(row.id);
    if (!id) continue;
    const attemptRow = latest.get(id);
    if (!attemptRow) continue;
    const requester = str(row.requester_actor_ref_id);
    const recipient = str(row.recipient_actor_ref_id);
    if (!requester || !recipient) continue;
    const attempt: AttemptView = {
      id: str(attemptRow.id) ?? "",
      request_id: id,
      state: str(attemptRow.state) ?? "",
      revision: num(attemptRow.revision) ?? 1,
      terms_revision: num(attemptRow.terms_revision) ?? 1,
      reply_due_at: str(attemptRow.reply_due_at),
      terms: record(attemptRow.terms) ?? {},
      created_at: str(attemptRow.created_at) ?? "",
    };
    if (!attempt.id) continue;
    result.push({
      request: {
        id,
        request_kind: str(row.request_kind) ?? "light",
        shared_title: str(row.shared_title) ?? "お願い",
        due_at: str(row.due_at),
        requester_actor_ref_id: requester,
        recipient_actor_ref_id: recipient,
        revision: num(row.revision) ?? 1,
      },
      attempt,
      party: requester === selfActorRef ? "requester" : "recipient",
    });
  }
  return result;
}

function requestActionData(view: { request: RequestView; attempt: AttemptView }, action: string): string {
  return encodeFields("mc_request", {
    request_id: view.request.id,
    attempt_id: view.attempt.id,
    request_action: action,
    revision: view.attempt.revision,
    terms_revision: view.attempt.terms_revision,
  });
}

async function openRequests(ctx: LineMustCompleteContext): Promise<void> {
  const views = await activeRequests(ctx, true);
  const view = views[0];
  if (!view) {
    await ctx.reply("いま返事・相談できるお願いはありません。");
    return;
  }
  const { request, attempt, party } = view;
  const summary = `${request.shared_title}\n返事期限: ${formatJst(attempt.reply_due_at)}\n作業期限: ${formatJst(request.due_at)}\n状態: ${attempt.state}`;
  const quick: LineQuickReplyAction[] = [];
  if (attempt.state === "expired") {
    if (party === "requester") quick.push(postback("再提案する", encodeFields("mc_request_repropose", { request_id: request.id, request_revision: request.revision })));
  } else if (party === "recipient" && ["pending", "checking"].includes(attempt.state)) {
    quick.push(postback("やる", requestActionData(view, "accept")));
    quick.push(postback("難しい", requestActionData(view, "decline")));
    if (attempt.state === "pending") quick.push(postback("確認中", requestActionData(view, "checking")));
    quick.push(postback("相談する", requestActionData(view, "consult")));
  } else if (["consulting", "awaiting_confirmation"].includes(attempt.state)) {
    quick.push(postback("この条件で確認", requestActionData(view, "confirm_terms")));
    quick.push(message("作業期限を変更", "条件期限 2026-09-11 18:30"));
  }
  await ctx.reply(`${summary}\n\n相談メモだけでは担当・作業期限は変わりません。変更する場合は、保存された具体的な条件を二人が同じ版で確認します。`, quick);
}

async function transitionRequest(ctx: LineMustCompleteContext, fields: Record<string, string>): Promise<void> {
  const requestId = fields.request_id;
  const attemptId = fields.attempt_id;
  const action = fields.request_action;
  const revision = Number(fields.revision);
  const termsRevision = Number(fields.terms_revision);
  if (!requestId || !attemptId || !action || !Number.isFinite(revision) || !Number.isFinite(termsRevision)) return;
  if (!["accept", "decline", "checking", "consult", "confirm_terms"].includes(action)) return;
  const operationId = await deterministicOperationId("line-request", ctx.eventId, requestId, attemptId, action, String(revision), String(termsRevision));
  const { data, error } = await ctx.client.rpc("server_tx_transition_request_v2", {
    p_actor_id: ctx.actorId,
    p_operation_id: operationId,
    p_request_id: requestId,
    p_attempt_id: attemptId,
    p_action: action,
    p_terms: null,
    p_expected_revision: revision,
    p_expected_terms_revision: termsRevision,
    p_source: "line",
  });
  if (error) {
    await replyMutationError(ctx, error);
    return;
  }
  const root = record(data);
  const state = str(root?.state) ?? action;
  if (state === "awaiting_confirmation") {
    await ctx.reply("✓ この条件版を確認しました。もう一人が同じ条件版を確認すると確定します。", [message("お願いを確認", "お願いの返事")]);
  } else if (state === "accepted") {
    await ctx.reply("✓ 合意を確定し、同じcanonical Taskへ反映しました。今日の表示も同じ状態を読みます。", [message("今日を確認", "今日")]);
  } else if (state === "expired") {
    await ctx.reply("返事期限を過ぎています。依頼した側から再提案してください。", [message("お願いを確認", "お願いの返事")]);
  } else {
    await ctx.reply(`✓ お願いを「${state}」に更新しました。`, [message("お願いを確認", "お願いの返事")]);
  }
}

async function editConsultationMemo(ctx: LineMustCompleteContext, memo: string): Promise<void> {
  const views = (await activeRequests(ctx)).filter((view) => ["consulting", "awaiting_confirmation"].includes(view.attempt.state));
  if (views.length !== 1) {
    await ctx.reply("相談中のお願いを1件に絞れませんでした。先に「お願いの返事」で対象を確認してください。");
    return;
  }
  const view = views[0];
  const terms: JsonObject = { ...view.attempt.terms, candidate: memo };
  const operationId = await deterministicOperationId("line-request-memo", ctx.eventId, view.attempt.id, memo, String(view.attempt.revision));
  const { error } = await ctx.client.rpc("server_tx_transition_request_v2", {
    p_actor_id: ctx.actorId, p_operation_id: operationId, p_request_id: view.request.id,
    p_attempt_id: view.attempt.id, p_action: "edit_terms", p_terms: terms,
    p_expected_revision: view.attempt.revision, p_expected_terms_revision: view.attempt.terms_revision, p_source: "line",
  });
  if (error) { await replyMutationError(ctx, error); return; }
  await ctx.reply("✓ 相談メモを条件版に保存しました。この文章だけでは担当・Task・作業期限は変わりません。具体的な変更は別に明示して、二人で同じ版を確認します。", [message("お願いを確認", "お願いの返事")]);
}

async function editStructuredDue(ctx: LineMustCompleteContext, dueIso: string): Promise<void> {
  const views = (await activeRequests(ctx)).filter((view) => ["consulting", "awaiting_confirmation"].includes(view.attempt.state));
  if (views.length !== 1) {
    await ctx.reply("変更する相談を1件に絞れませんでした。先に「お願いの返事」で対象を確認してください。状態は変更していません。");
    return;
  }
  const view = views[0];
  const oldTerms = view.attempt.terms;
  const materialPatch: JsonObject = { version: 1, work_due_at: dueIso };
  if (view.request.request_kind === "assignment_change") {
    const targets = oldTerms.assignment_targets;
    if (!Array.isArray(targets) || targets.length === 0) {
      await ctx.reply("担当変更の対象を安全に確認できません。再提案してください。");
      return;
    }
    materialPatch.assignment = { mode: "request_recipient", targets };
  }
  const terms: JsonObject = { ...oldTerms, material_patch: materialPatch };
  const operationId = await deterministicOperationId("line-request-edit-terms", ctx.eventId, view.attempt.id, dueIso, String(view.attempt.revision));
  const { error } = await ctx.client.rpc("server_tx_transition_request_v2", {
    p_actor_id: ctx.actorId,
    p_operation_id: operationId,
    p_request_id: view.request.id,
    p_attempt_id: view.attempt.id,
    p_action: "edit_terms",
    p_terms: terms,
    p_expected_revision: view.attempt.revision,
    p_expected_terms_revision: view.attempt.terms_revision,
    p_source: "line",
  });
  if (error) {
    await replyMutationError(ctx, error);
    return;
  }
  await ctx.reply(`条件を提案しました。\n作業期限: ${formatJst(view.request.due_at)} → ${formatJst(dueIso)}\n担当変更がある依頼では、対象Taskと相手も同じ条件版に固定されています。\n\nまだTaskは変更していません。二人がこの条件版を確認すると確定します。`, [message("条件を確認", "お願いの返事")]);
}

async function reproposeRequest(ctx: LineMustCompleteContext, fields: Record<string, string>): Promise<void> {
  const requestId = fields.request_id;
  const requestRevision = Number(fields.request_revision);
  if (!requestId || !Number.isFinite(requestRevision)) return;
  const operationId = await deterministicOperationId("line-request-repropose", ctx.eventId, requestId, String(requestRevision));
  const replyDueAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
  const { error } = await ctx.client.rpc("server_tx_repropose_request_v1", {
    p_actor_id: ctx.actorId,
    p_operation_id: operationId,
    p_request_id: requestId,
    p_expected_request_revision: requestRevision,
    p_reply_due_at: replyDueAt,
    p_source: "line",
  });
  if (error) {
    await replyMutationError(ctx, error);
    return;
  }
  await ctx.reply(`✓ 再提案しました。新しい返事期限: ${formatJst(replyDueAt)}`, [message("お願いを確認", "お願いの返事")]);
}

function simulationRoleLabel(value: unknown): string {
  const root = record(value);
  return str(root?.simulated_display_label) ?? (str(root?.simulated_role) === "papa" ? "🧪 パパ" : "🧪 ママ");
}

function simulationStateLabel(state: string | null): string {
  switch (state) {
    case "pending": return "返事待ち";
    case "checking": return "確認中";
    case "consulting": return "相談中";
    case "awaiting_confirmation": return "条件確認待ち";
    case "accepted": return "受けました";
    case "declined": return "断りました";
    case "cancelled": return "取り消し";
    case "expired": return "返事期限切れ";
    default: return state ?? "不明";
  }
}

function simulationDirectionLabels(
  request: JsonObject | null,
  simulatedLabel: string,
): { requester: string; recipient: string } {
  return {
    requester: str(request?.requester_side) === "simulated" ? simulatedLabel : "あなた",
    recipient: str(request?.recipient_side) === "simulated" ? simulatedLabel : "あなた",
  };
}

function simulationRequestText(root: JsonObject, request: JsonObject): string {
  const simulatedLabel = simulationRoleLabel(root);
  const labels = simulationDirectionLabels(request, simulatedLabel);
  const attempt = record(request.latest_attempt);
  const title = str(request.title) ?? "お願い";
  const detail = str(request.message);
  const state = simulationStateLabel(str(attempt?.state) ?? str(request.status));
  const lines = [
    `1人テスト｜${labels.recipient}として確認`,
    `${labels.requester}からお願いが届いています`,
    "",
    title,
  ];
  if (detail) lines.push(`内容: ${detail}`);
  lines.push(
    `返事期限: ${formatJst(str(attempt?.reply_due_at))}`,
    `作業期限: ${formatJst(str(request.due_at))}`,
    `状態: ${state}`,
    "",
    `${labels.recipient}として返事してください。`,
    "※本物の家族・providerには送りません。",
  );
  return lines.join("\n");
}

function simulationControls(
  contextId: string,
  revision: number | null,
  simulatedLabel: string,
): LineQuickReplyAction[] {
  const quick: LineQuickReplyAction[] = [
    postback(`${simulatedLabel}にお願い`, encodeFields("mc_sim_send", {
      test_context_id: contextId,
      direction: "operator_to_simulated",
    })),
    postback(`${simulatedLabel}からお願い`, encodeFields("mc_sim_send", {
      test_context_id: contextId,
      direction: "simulated_to_operator",
    })),
    postback("最新のお願いを見る", encodeFields("mc_sim_view", { test_context_id: contextId })),
  ];
  if (revision) {
    quick.push(postback("1人テスト終了", encodeFields("mc_sim_archive", {
      test_context_id: contextId,
      revision,
    })));
  }
  return quick;
}

async function openSimulation(ctx: LineMustCompleteContext): Promise<void> {
  const { data, error } = await ctx.client.rpc("server_tx_get_active_test_simulation_v1", { p_actor_id: ctx.actorId });
  if (error) {
    await replyMutationError(ctx, error);
    return;
  }
  const root = record(data);
  if (root?.active !== true) {
    await ctx.reply("1人テストを開始する役を選んでください。あなた1人で相手側の画面・返事まで試せます。本物の家族へのLINE送信やGoogle更新はしません。", [
      postback("ママ役で試す", encodeFields("mc_sim_open", { role: "mama" })),
      postback("パパ役で試す", encodeFields("mc_sim_open", { role: "papa" })),
    ]);
    return;
  }
  const contextId = str(root.test_context_id);
  const revision = num(root.revision);
  if (!contextId || !revision) return;
  const simulatedLabel = simulationRoleLabel(root);
  await ctx.reply(
    `1人テスト中：${simulatedLabel}\nあなた1人で、${simulatedLabel}に届くお願い／${simulatedLabel}から届くお願いを確認できます。\n本物の家族・providerへ副作用は出ません。`,
    simulationControls(contextId, revision, simulatedLabel),
  );
}

async function mutateSimulation(ctx: LineMustCompleteContext, fields: Record<string, string>): Promise<void> {
  if (fields.action === "mc_sim_open") {
    const role = fields.role === "papa" ? "papa" : "mama";
    const operationId = await deterministicOperationId("line-sim-open", ctx.eventId, role);
    const { data, error } = await ctx.client.rpc("server_tx_open_test_simulation_interactive_v1", {
      p_actor_id: ctx.actorId,
      p_operation_id: operationId,
      p_simulated_role: role,
      p_label: "LINE one-user simulation",
    });
    if (error) {
      await replyMutationError(ctx, error);
      return;
    }
    const root = record(data);
    const simulatedLabel = simulationRoleLabel(root ?? { simulated_role: role });
    await ctx.reply(
      `✓ 1人テストを開始しました。相手役は ${simulatedLabel} です。本物の家族には送りません。`,
      [message("テスト画面を見る", "テスト状態")],
    );
    return;
  }

  const contextId = fields.test_context_id;
  if (!contextId) return;

  if (fields.action === "mc_sim_send") {
    const direction = fields.direction === "simulated_to_operator" ? "simulated_to_operator" : "operator_to_simulated";
    const toSimulated = direction === "operator_to_simulated";
    const title = toSimulated ? "お迎えをお願い" : "洗濯をお願い";
    const sharedMessage = toSimulated
      ? "今日のお迎えをお願いできますか？"
      : "今日の洗濯をお願いできますか？";
    const operationId = await deterministicOperationId("line-sim-send", ctx.eventId, contextId, direction);
    const { error } = await ctx.client.rpc("server_tx_test_simulation_send_request_v1", {
      p_actor_id: ctx.actorId,
      p_test_context_id: contextId,
      p_operation_id: operationId,
      p_direction: direction,
      p_shared_title: title,
      p_shared_message: sharedMessage,
      p_due_at: new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString(),
    });
    if (error) {
      await replyMutationError(ctx, error);
      return;
    }

    const { data: simData } = await ctx.client.rpc("server_tx_get_active_test_simulation_v1", {
      p_actor_id: ctx.actorId,
    });
    const simulatedLabel = simulationRoleLabel(simData);
    const target = toSimulated ? simulatedLabel : "あなた";
    const sender = toSimulated ? "あなた" : simulatedLabel;
    await ctx.reply(
      `✓ ${sender} → ${target} のテスト用お願いを作りました。\n「${title}」\n本物の家族には送りません。`,
      [postback(`${target}側で確認`, encodeFields("mc_sim_view", { test_context_id: contextId }))],
    );
    return;
  }

  if (fields.action === "mc_sim_view") {
    const { data, error } = await ctx.client.rpc("server_tx_get_test_simulation_workspace_v2", {
      p_actor_id: ctx.actorId,
      p_test_context_id: contextId,
    });
    if (error) {
      await replyMutationError(ctx, error);
      return;
    }
    const root = record(data);
    if (!root) return;
    const requestRows = records(root.requests ?? []);
    const latest = requestRows[0];
    const simulatedLabel = simulationRoleLabel(root);
    const revision = num(root.revision);
    const quick: LineQuickReplyAction[] = [];

    if (!latest) {
      await ctx.reply(
        `1人テスト中：${simulatedLabel}\nまだお願いはありません。\n本物の家族・providerへ副作用は出ません。`,
        simulationControls(contextId, revision, simulatedLabel),
      );
      return;
    }

    const latestAttempt = record(latest.latest_attempt);
    if (latestAttempt && ["pending", "checking"].includes(str(latestAttempt.state) ?? "")) {
      const requestId = str(latest.request_id);
      const attemptId = str(latestAttempt.attempt_id);
      const attemptRevision = num(latestAttempt.revision);
      const termsRevision = num(latestAttempt.terms_revision);
      const labels = simulationDirectionLabels(latest, simulatedLabel);
      if (requestId && attemptId && attemptRevision && termsRevision) {
        quick.push(postback(`${labels.recipient}として受ける`, encodeFields("mc_sim_respond", {
          test_context_id: contextId,
          request_id: requestId,
          attempt_id: attemptId,
          revision: attemptRevision,
          terms_revision: termsRevision,
          response: "accept",
        })));
        quick.push(postback(`${labels.recipient}として断る`, encodeFields("mc_sim_respond", {
          test_context_id: contextId,
          request_id: requestId,
          attempt_id: attemptId,
          revision: attemptRevision,
          terms_revision: termsRevision,
          response: "decline",
        })));
      }
    }

    quick.push(...simulationControls(contextId, revision, simulatedLabel).filter((item) =>
      item.type !== "postback" || !item.data.includes("action=mc_sim_view")
    ));
    await ctx.reply(simulationRequestText(root, latest), quick);
    return;
  }

  if (fields.action === "mc_sim_respond") {
    const revision = Number(fields.revision);
    const termsRevision = Number(fields.terms_revision);
    if (!fields.request_id || !fields.attempt_id || !Number.isFinite(revision) || !Number.isFinite(termsRevision)) return;
    const action = fields.response === "decline" ? "decline" : "accept";
    const operationId = await deterministicOperationId("line-sim-respond", ctx.eventId, contextId, fields.attempt_id, action);
    const { error } = await ctx.client.rpc("server_tx_test_simulation_respond_request_v1", {
      p_actor_id: ctx.actorId,
      p_test_context_id: contextId,
      p_operation_id: operationId,
      p_request_id: fields.request_id,
      p_attempt_id: fields.attempt_id,
      p_action: action,
      p_expected_revision: revision,
      p_expected_terms_revision: termsRevision,
    });
    if (error) {
      await replyMutationError(ctx, error);
      return;
    }
    await ctx.reply(
      action === "accept"
        ? "✓ テスト相手として「受ける」を記録しました。本物の家族には送っていません。"
        : "✓ テスト相手として「断る」を記録しました。本物の家族には送っていません。",
      [postback("結果を見る", encodeFields("mc_sim_view", { test_context_id: contextId }))],
    );
    return;
  }

  if (fields.action === "mc_sim_archive") {
    const revision = Number(fields.revision);
    if (!Number.isFinite(revision)) return;
    const operationId = await deterministicOperationId("line-sim-archive", ctx.eventId, contextId, String(revision));
    const { error } = await ctx.client.rpc("server_tx_archive_test_simulation_v1", {
      p_actor_id: ctx.actorId,
      p_operation_id: operationId,
      p_test_context_id: contextId,
      p_expected_revision: revision,
    });
    if (error) await replyMutationError(ctx, error);
    else await ctx.reply("✓ 1人テストを終了しました。テスト状態が本番Taskへ変換されることはありません。");
  }
}

export async function tryHandleLineMustCompleteText(ctx: LineMustCompleteContext, rawText: string): Promise<boolean> {
  const text = rawText.normalize("NFKC").trim();
  const memoMatch = text.match(/^相談メモ[：:\s]+(.{1,500})$/u);
  if (memoMatch) {
    await editConsultationMemo(ctx, memoMatch[1].trim());
    return true;
  }
  const dueIso = parseStructuredWorkDue(text);
  if (dueIso) {
    await editStructuredDue(ctx, dueIso);
    return true;
  }
  if (/^条件期限\b/u.test(text)) {
    await ctx.reply("作業期限の変更は `条件期限 2026-09-11 18:30` の形で送ってください。自由文からTaskを自動変更することはありません。");
    return true;
  }
  if (isDailyInputText(text)) {
    await openReconciliation(ctx);
    return true;
  }
  if (isWaitingText(text)) {
    await openWaiting(ctx);
    return true;
  }
  if (isShoppingText(text)) {
    await openShopping(ctx);
    return true;
  }
  if (isRequestText(text)) {
    await openRequests(ctx);
    return true;
  }
  if (isHandoverReviewText(text)) {
    await openHandoverReview(ctx);
    return true;
  }
  if (isSimulationText(text)) {
    await openSimulation(ctx);
    return true;
  }
  return false;
}

export async function tryHandleLineMustCompletePostback(
  ctx: LineMustCompleteContext,
  fields: Record<string, string>,
): Promise<boolean> {
  const action = fields.action;
  if (action === "mc_reconcile") {
    await reconcile(ctx, fields);
    return true;
  }
  if (action === "mc_reconcile_undo" && fields.target_operation_id) {
    await undoReconciliation(ctx, fields.target_operation_id);
    return true;
  }
  if (action === "mc_wait_select") {
    await setWaiting(ctx, fields, "set");
    return true;
  }
  if (action === "mc_wait_set") {
    await setWaiting(ctx, fields, "set");
    return true;
  }
  if (action === "mc_wait_resume") {
    await setWaiting(ctx, fields, "resume");
    return true;
  }
  if (action === "mc_wait_update") {
    await setWaiting(ctx, fields, "update");
    return true;
  }
  if (action === "mc_shopping") {
    await mutateShopping(ctx, fields);
    return true;
  }
  if (action === "mc_request") {
    await transitionRequest(ctx, fields);
    return true;
  }
  if (action === "mc_request_repropose") {
    await reproposeRequest(ctx, fields);
    return true;
  }
  if (await handleHandoverAckPostback(ctx, fields)) {
    return true;
  }
  if (action?.startsWith("mc_sim_")) {
    await mutateSimulation(ctx, fields);
    return true;
  }
  return false;
}

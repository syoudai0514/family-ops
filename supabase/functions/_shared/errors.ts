// Error envelope shared by every user-facing Edge Function.
// docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md #16 (error envelope),
// #14/#15 in 18_MUTATION_CONTRACT_MATRIX.md (error code catalogue).
import { corsHeaders } from "./cors.ts";

export class FamilyOpsError extends Error {
  code: string;
  httpStatus: number;
  // Optional structured extra (e.g. the existing invite id carried in
  // server_tx_create_household_invite's INVITE_TOKEN_ALREADY_ISSUED DETAIL).
  detail?: string;

  constructor(code: string, message: string, httpStatus = 400, detail?: string) {
    super(message);
    this.code = code;
    this.httpStatus = httpStatus;
    this.detail = detail;
  }
}

const HTTP_STATUS_BY_CODE: Record<string, number> = {
  UNAUTHENTICATED: 401,
  NOT_HOUSEHOLD_MEMBER: 403,
  CROSS_HOUSEHOLD_RESOURCE: 403,
  IDEMPOTENCY_CONFLICT: 409,
  INVALID_INPUT: 400,
  HOUSEHOLD_ALREADY_JOINED: 409,
  HOUSEHOLD_FULL: 409,
  INVITE_EXPIRED: 410,
  INVITE_USED: 410,
  INVITE_TOKEN_ALREADY_ISSUED: 409,
  EDGE_WORKER_UNAUTHORIZED: 401,
  INTERNAL_ERROR: 500,
  // WP2 additions (task/request/shopping mutation boundary):
  TASK_TERMINAL: 409,
  REQUEST_NOT_PENDING: 409,
  REQUEST_NOT_RECIPIENT: 403,
  REQUEST_NOT_REQUESTER: 403,
  REQUEST_CANCEL_NOT_ALLOWED: 409,
  INVALID_SHOPPING_TRANSITION: 409,
  AGGREGATE_REVISION_CONFLICT: 409,
  REQUEST_ATTEMPT_STALE: 409,
  REQUEST_TRANSITION_INVALID: 409,
  REQUEST_AGREEMENT_NOT_ESTABLISHED: 409,
  REQUEST_FOLLOWUP_KIND_INVALID: 400,
  REQUEST_TERMS_REQUIRED: 400,
  REQUEST_TERMS_FIELD_INVALID: 400,
  ASSIGNMENT_MODE_INVALID: 400,
  ASSIGNMENT_MODE_REQUIRED: 400,
  ASSIGNMENT_MODE_ACTOR_MISMATCH: 400,
  SHOPPING_ITEM_NOT_FOUND: 404,
  SHOPPING_CLAIM_ACTION_INVALID: 400,
  SHOPPING_NOT_CLAIMABLE: 409,
  SHOPPING_ALREADY_CLAIMED: 409,
  SHOPPING_CLAIM_NOT_OWNED: 409,
  SHOPPING_TAKEOVER_NOT_REQUIRED: 409,
  SHOPPING_CLAIMED_BY_OTHER: 409,
  SHOPPING_PERFORMER_NOT_ASSIGNEE: 409,
  CORRECTION_REASON_REQUIRED: 400,
  RECURRENCE_OVERLAP: 409,
  // WP5 additions (Gemini AI-draft boundary):
  AI_INVARIANT_VIOLATION: 422,
  AI_UNAVAILABLE: 503,
  RAW_INPUT_EXPIRED: 410,
  // WP7 additions (Google Calendar boundary; see docs/adr/0005 — these were
  // first served from googleCalendar.ts's own GOOGLE_ERROR_STATUS map for
  // collision-avoidance reasons during parallel WP6/WP7 development, and are
  // now folded into the shared catalogue as that ADR's own recommended
  // follow-up):
  GOOGLE_OAUTH_STATE_INVALID: 400,
  CALENDAR_TIMEZONE_UNSUPPORTED: 422,
  CALENDAR_NO_ELIGIBLE_CALENDAR: 422,
  CALENDAR_ETAG_CONFLICT: 409,
  CALENDAR_REAUTH_REQUIRED: 409,
  CALENDAR_UNAVAILABLE: 503,
  CALENDAR_EVENT_NOT_FOUND: 404,
  GOOGLE_SYNC_LEASE_LOST: 409,
};

// v6 review fix (P2): any code we don't explicitly classify as a client
// error is treated as a server fault (500), not silently downgraded to 400.
// A missing entry in HTTP_STATUS_BY_CODE should fail loud in review, not
// masquerade as "bad request".
export function statusForCode(code: string): number {
  return HTTP_STATUS_BY_CODE[code] ?? 500;
}

// Never includes secret/raw provider payload — only a stable code + a short
// human message (plus an optional non-secret `detail`), matching the
// normative envelope shape.
export function errorResponse(code: string, message: string, detail?: string): Response {
  return new Response(
    JSON.stringify({ error: { code, message, ...(detail ? { detail } : {}) } }),
    {
      status: statusForCode(code),
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    },
  );
}

const KNOWN_CODES = new Set([
  "UNAUTHENTICATED",
  "NOT_HOUSEHOLD_MEMBER",
  "CROSS_HOUSEHOLD_RESOURCE",
  "IDEMPOTENCY_CONFLICT",
  "INVALID_INPUT",
  "HOUSEHOLD_ALREADY_JOINED",
  "HOUSEHOLD_FULL",
  "INVITE_EXPIRED",
  "INVITE_USED",
  "INVITE_TOKEN_ALREADY_ISSUED",
  "TASK_TERMINAL",
  "REQUEST_NOT_PENDING",
  "REQUEST_NOT_RECIPIENT",
  "REQUEST_NOT_REQUESTER",
  "REQUEST_CANCEL_NOT_ALLOWED",
  "INVALID_SHOPPING_TRANSITION",
  "AGGREGATE_REVISION_CONFLICT",
  "REQUEST_ATTEMPT_STALE",
  "REQUEST_TRANSITION_INVALID",
  "REQUEST_AGREEMENT_NOT_ESTABLISHED",
  "REQUEST_FOLLOWUP_KIND_INVALID",
  "REQUEST_TERMS_REQUIRED",
  "REQUEST_TERMS_FIELD_INVALID",
  "ASSIGNMENT_MODE_INVALID",
  "ASSIGNMENT_MODE_REQUIRED",
  "ASSIGNMENT_MODE_ACTOR_MISMATCH",
  "SHOPPING_ITEM_NOT_FOUND",
  "SHOPPING_CLAIM_ACTION_INVALID",
  "SHOPPING_NOT_CLAIMABLE",
  "SHOPPING_ALREADY_CLAIMED",
  "SHOPPING_CLAIM_NOT_OWNED",
  "SHOPPING_TAKEOVER_NOT_REQUIRED",
  "SHOPPING_CLAIMED_BY_OTHER",
  "SHOPPING_PERFORMER_NOT_ASSIGNEE",
  "CORRECTION_REASON_REQUIRED",
  "RECURRENCE_OVERLAP",
  "AI_INVARIANT_VIOLATION",
  "AI_UNAVAILABLE",
  "RAW_INPUT_EXPIRED",
  "GOOGLE_OAUTH_STATE_INVALID",
  "CALENDAR_TIMEZONE_UNSUPPORTED",
  "CALENDAR_NO_ELIGIBLE_CALENDAR",
  "CALENDAR_ETAG_CONFLICT",
  "CALENDAR_REAUTH_REQUIRED",
  "CALENDAR_UNAVAILABLE",
  "CALENDAR_EVENT_NOT_FOUND",
  "GOOGLE_SYNC_LEASE_LOST",
]);

export function isKnownErrorCode(code: string): boolean {
  return KNOWN_CODES.has(code);
}

export function describeCode(code: string): string {
  switch (code) {
    case "IDEMPOTENCY_CONFLICT":
      return "同じ操作IDで異なる内容が送信されました";
    case "HOUSEHOLD_ALREADY_JOINED":
      return "既にいずれかの家庭に参加しています";
    case "HOUSEHOLD_FULL":
      return "この家庭には既に2人の大人が参加しています";
    case "INVITE_EXPIRED":
      return "招待の有効期限が切れています";
    case "INVITE_USED":
      return "この招待は既に使用されています";
    case "INVITE_TOKEN_ALREADY_ISSUED":
      return "招待トークンは既に発行済みです。新しい招待を作成してください";
    case "NOT_HOUSEHOLD_MEMBER":
      return "家庭のメンバーではありません";
    case "INVALID_INPUT":
      return "入力内容が不正です";
    case "TASK_TERMINAL":
      return "このタスクは既に完了・キャンセル・スキップされています";
    case "REQUEST_NOT_PENDING":
      return "このお願いは既に対応済みです";
    case "REQUEST_NOT_RECIPIENT":
      return "このお願いの宛先ではありません";
    case "REQUEST_NOT_REQUESTER":
      return "このお願いの送信者ではありません";
    case "REQUEST_CANCEL_NOT_ALLOWED":
      return "承諾済みのお願いはキャンセルできません";
    case "INVALID_SHOPPING_TRANSITION":
      return "この買い物アイテムの状態では実行できません";
    case "AGGREGATE_REVISION_CONFLICT":
    case "REQUEST_ATTEMPT_STALE":
      return "状態が更新されています。最新の内容を確認してください";
    case "REQUEST_TRANSITION_INVALID":
    case "REQUEST_AGREEMENT_NOT_ESTABLISHED":
      return "このお願いには現在その操作を行えません";
    case "REQUEST_FOLLOWUP_KIND_INVALID":
    case "REQUEST_TERMS_REQUIRED":
    case "REQUEST_TERMS_FIELD_INVALID":
      return "変更提案の内容を確認してください";
    case "ASSIGNMENT_MODE_INVALID":
    case "ASSIGNMENT_MODE_REQUIRED":
    case "ASSIGNMENT_MODE_ACTOR_MISMATCH":
      return "担当方法と担当者の組み合わせを確認してください";
    case "SHOPPING_ITEM_NOT_FOUND":
      return "買い物項目が見つかりません";
    case "SHOPPING_CLAIM_ACTION_INVALID":
      return "担当操作を確認してください";
    case "SHOPPING_NOT_CLAIMABLE":
    case "SHOPPING_ALREADY_CLAIMED":
    case "SHOPPING_CLAIM_NOT_OWNED":
    case "SHOPPING_TAKEOVER_NOT_REQUIRED":
    case "SHOPPING_CLAIMED_BY_OTHER":
    case "SHOPPING_PERFORMER_NOT_ASSIGNEE":
      return "担当状況が更新されています。最新の内容を確認してください";
    case "CORRECTION_REASON_REQUIRED":
      return "未対応に戻す理由を入力してください";
    case "RECURRENCE_OVERLAP":
      return "同じ曜日・時間帯の設定が重複しています";
    case "AI_INVARIANT_VIOLATION":
      return "AIの提案内容が元のメモと矛盾しています。内容を確認してください";
    case "AI_UNAVAILABLE":
      return "AI機能に一時的に接続できません。しばらくしてから再度お試しください";
    case "RAW_INPUT_EXPIRED":
      return "下書きの有効期限が切れています。もう一度入力し直してください";
    case "GOOGLE_OAUTH_STATE_INVALID":
      return "連携の有効期限が切れました。もう一度連携をやり直してください";
    case "CALENDAR_TIMEZONE_UNSUPPORTED":
      return "選択したカレンダーのタイムゾーンに対応していません";
    case "CALENDAR_NO_ELIGIBLE_CALENDAR":
      return "書き込み可能なカレンダーが見つかりませんでした";
    case "CALENDAR_ETAG_CONFLICT":
      return "予定が他の場所で変更されています。最新の内容を確認してください";
    case "CALENDAR_REAUTH_REQUIRED":
      return "Googleカレンダーとの連携が切れています。再連携してください";
    case "CALENDAR_UNAVAILABLE":
      return "Googleカレンダーに一時的に接続できません。しばらくしてから再度お試しください";
    case "CALENDAR_EVENT_NOT_FOUND":
      return "対象の予定が見つかりませんでした";
    case "GOOGLE_SYNC_LEASE_LOST":
      return "同期処理が別のワーカーに引き継がれました";
    default:
      return code;
  }
}

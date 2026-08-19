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
  RECURRENCE_OVERLAP: 409,
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
  "RECURRENCE_OVERLAP",
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
    case "RECURRENCE_OVERLAP":
      return "同じ曜日・時間帯の設定が重複しています";
    default:
      return code;
  }
}

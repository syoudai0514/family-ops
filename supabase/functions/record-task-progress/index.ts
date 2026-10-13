// Optional progress never completes a task or changes its planned performer.
// verify_jwt=true; actor identity comes exclusively from auth.getUser().
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import { jsonResponse, withUserMutationHandler } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NOTE_FIELDS = ["observed_note", "work_done_note", "remaining_note", "next_step_note"] as const;

function isIsoDateTime(value: unknown): value is string {
  if (typeof value !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) ||
    Number.isNaN(Date.parse(value))) return false;
  // Date.parse normalizes e.g. February 30 rather than rejecting it. Validate
  // the calendar date separately before PostgREST's typed timestamp parsing.
  const date = value.slice(0, 10);
  const midnight = new Date(`${date}T00:00:00Z`);
  return Number.isFinite(midnight.getTime()) && midnight.toISOString().slice(0, 10) === date;
}

Deno.serve(withUserMutationHandler(async (req) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  if (!UUID.test(operationId) || typeof body.task_id !== "string" || !UUID.test(body.task_id) ||
    !Number.isSafeInteger(body.expected_revision) || Number(body.expected_revision) < 1 ||
    typeof body.share_with_household !== "boolean" ||
    (body.ack_policy !== "none" && body.ack_policy !== "required")) {
    throw new FamilyOpsError("INVALID_INPUT", "作業と記録内容を確認してください", 400);
  }
  const notes: Record<string, string | null> = {};
  let totalLength = 0;
  for (const field of NOTE_FIELDS) {
    const value = body[field];
    if (value != null && (typeof value !== "string" || value.length > 2000)) {
      throw new FamilyOpsError("INVALID_INPUT", "各メモは2,000文字以内で入力してください", 400);
    }
    totalLength += typeof value === "string" ? value.length : 0;
    notes[`p_${field}`] = typeof value === "string" ? value.trim() || null : null;
  }
  const validUntil = body.valid_until;
  if (totalLength > 8000 || !Object.values(notes).some(Boolean) ||
    (validUntil != null && !isIsoDateTime(validUntil)) ||
    (!body.share_with_household && (body.ack_policy !== "none" || validUntil != null))) {
    throw new FamilyOpsError("INVALID_INPUT", "記録内容と共有の設定を確認してください", 400);
  }
  return jsonResponse(await callServerTx(createServiceRoleClient(), "server_tx_record_task_progress", {
    p_actor_id: actorId,
    p_operation_id: operationId,
    p_task_id: body.task_id,
    p_expected_revision: body.expected_revision,
    ...notes,
    p_share_with_household: body.share_with_household,
    p_ack_policy: body.ack_policy,
    p_valid_until: validUntil ?? null,
  }));
}));

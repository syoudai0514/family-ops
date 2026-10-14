// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// Sol re-review #3 fix (P1-1, docs/adr/0011): the PWA half of confirming a
// LINE-created draft pending action (docs/design/v6/06_LINE_INTEGRATION.md
// #9 "Confirmation postback itself never performs external side-effect
// inline; it marks confirmed then worker executes") -- process-line-inbox
// already calls this exact RPC for its own `confirm_pending` postback
// (supabase/functions/process-line-inbox/index.ts); this wraps the SAME
// server_tx_confirm_pending_action (20260819000041, unchanged) for the PWA
// caller instead, with the same (p_actor_id, p_pending_action_id) shape --
// no operation_id, matching that RPC's own signature (its idempotency is
// the status-check "already confirmed -> no-op replay" pattern the RPC
// itself already implements, not the mutation_receipts/operation_id
// pattern most other server_tx_* mutations use).
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { jsonResponse, withUserMutationHandler } from "../_shared/handler.ts";
import { callServerTx, readJsonBody } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import { parseTransportAssignmentText } from "../_shared/transportAssignmentIntent.ts";

function storedDateLabel(value: unknown): string | null {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/u.test(value)) {
    return null;
  }
  const parsed = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(parsed.getTime()) &&
      parsed.toISOString().slice(0, 10) === value
    ? value
    : null;
}

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);

  const pendingActionId = body["pending_action_id"];
  if (typeof pendingActionId !== "string" || pendingActionId.length === 0) {
    throw new FamilyOpsError(
      "INVALID_INPUT",
      "pending_action_id is required",
      400,
    );
  }

  const serviceClient = createServiceRoleClient();
  const { data: pending, error: pendingError } = await serviceClient.rpc(
    "server_tx_get_pending_action",
    { p_actor_id: actorId, p_pending_action_id: pendingActionId },
  );
  if (pendingError) {
    // The getter deliberately uses the same error for terminal, expired,
    // nonexistent and other-actor rows. Only this exact known result may use
    // the original confirm boundary, which preserves successful replay and
    // still rejects expired/foreign rows with its own authorization checks.
    if (pendingError.message?.trim() !== "PENDING_ACTION_NOT_EDITABLE") {
      throw new FamilyOpsError(
        "INTERNAL_ERROR",
        "下書きの内容を確認できなかったため、送信していません。更新してから確認してください。",
        500,
      );
    }
  } else {
    if (
      !pending || pending.id !== pendingActionId ||
      pending.status !== "draft" ||
      typeof pending.action_type !== "string" || !pending.normalized_payload ||
      typeof pending.normalized_payload !== "object" ||
      Array.isArray(pending.normalized_payload)
    ) {
      throw new FamilyOpsError(
        "INTERNAL_ERROR",
        "下書きの内容を確認できなかったため、送信していません。更新してから確認してください。",
        500,
      );
    }
    if (["request_create", "task_create_once"].includes(pending.action_type)) {
      const payload = pending.normalized_payload as Record<string, unknown>;
      const raw =
        typeof payload.raw_text === "string" && payload.raw_text.trim()
          ? payload.raw_text
          : typeof payload.title === "string"
          ? payload.title
          : "";
      const intent = parseTransportAssignmentText(raw);
      if (intent) {
        // Never recalculate an old "明日" when its card is reopened later.
        const date = storedDateLabel(payload.scheduled_date);
        const subject = `${date ? `${date}の` : "対象日の"}${
          intent.code === "dropoff" ? "送り" : "お迎え"
        }`;
        throw new FamilyOpsError(
          "INVALID_INPUT",
          `${subject}は、この確認カードから担当を変更できません。当日の作業を開き、「担当を調整」から確認してください。送信・担当変更はしていません。`,
          400,
        );
      }
    }
  }
  const result = await callServerTx(
    serviceClient,
    "server_tx_confirm_pending_action",
    { p_actor_id: actorId, p_pending_action_id: pendingActionId },
  );

  return jsonResponse(result);
}));

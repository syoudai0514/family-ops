// Q17: Event planning is proposal-only here.  No family_event/task mutation
// occurs until confirm-event-plan calls the explicit human-confirmation RPC.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import { jsonResponse, withUserMutationHandler } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import {
  buildTemplateCandidates,
  isEventTemplateKey,
  proposeEventTodoCandidates,
} from "../_shared/eventPlanning.ts";

function text(value: unknown, max: number, required = false): string {
  if (value == null && !required) return "";
  if (typeof value !== "string") throw new FamilyOpsError("INVALID_INPUT", "入力形式が不正です", 400);
  const normalized = value.trim();
  if ((required && normalized.length === 0) || normalized.length > max) {
    throw new FamilyOpsError("INVALID_INPUT", "入力内容を確認してください", 400);
  }
  return normalized;
}

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);
  if (!isEventTemplateKey(body.template_key)) {
    throw new FamilyOpsError("INVALID_INPUT", "イベント種別を選んでください", 400);
  }
  const title = text(body.title, 240, true);
  const eventDate = text(body.event_date, 10, true);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(eventDate)) {
    throw new FamilyOpsError("INVALID_INPUT", "日付を確認してください", 400);
  }
  const details = text(body.details, 4000);
  const location = text(body.location, 500);

  const templateCandidates = buildTemplateCandidates(body.template_key, eventDate);
  let aiCandidates;
  try {
    aiCandidates = await proposeEventTodoCandidates({
      templateKey: body.template_key,
      eventDate,
      title,
      details,
      location,
    });
  } catch (error) {
    console.error("event AI proposal failed", { message: error instanceof Error ? error.message : String(error) });
    throw new FamilyOpsError(
      "AI_UNAVAILABLE",
      "AIの準備候補を作れませんでした。時間をおいて再度お試しください",
      503,
    );
  }

  const result = await callServerTx(createServiceRoleClient(), "server_tx_begin_event_planning_draft", {
    p_actor_id: actorId,
    p_operation_id: operationId,
    p_template_key: body.template_key,
    p_input_payload: { title, event_date: eventDate, details, location },
    p_template_candidates: templateCandidates,
    p_ai_candidates: aiCandidates,
  });
  return jsonResponse(result);
}));

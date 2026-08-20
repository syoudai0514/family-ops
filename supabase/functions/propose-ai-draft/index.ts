// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// WP5 "propose from raw input" — docs/adr/0003-ai-draft-propose-endpoint.md
// documents why this endpoint's name is not in the vendored v6 design
// matrix (a genuine gap, same pattern as configure-dropoff-pickup /
// docs/adr/0002). The AI preview itself is not a business mutation
// (18_MUTATION_CONTRACT_MATRIX.md #13): this stores the raw text privately,
// calls Gemini, validates the fact/quantity/date invariant, and returns the
// proposal — it never writes to public.requests/public.handovers. Only
// confirm-request-draft / confirm-handover-draft do that, after the user
// explicitly confirms (their own final edit, not necessarily the AI's raw
// output).
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import { proposeAiDraft, validateInvariant, type AiDraftTargetType } from "../_shared/gemini.ts";

const TARGET_TYPES: AiDraftTargetType[] = ["request", "handover"];
const RAW_INPUT_TTL_HOURS = Number(Deno.env.get("RAW_INPUT_TTL_HOURS") ?? "24");

function kindForTarget(targetType: AiDraftTargetType): "request_draft" | "handover_draft" {
  return targetType === "request" ? "request_draft" : "handover_draft";
}

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const rawText = body["raw_text"];
  const targetType = body["target_type"];
  if (typeof rawText !== "string" || rawText.trim().length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "raw_text is required", 400);
  }
  if (typeof targetType !== "string" || !TARGET_TYPES.includes(targetType as AiDraftTargetType)) {
    throw new FamilyOpsError("INVALID_INPUT", "target_type must be 'request' or 'handover'", 400);
  }

  const serviceClient = createServiceRoleClient();

  // 1. Store the raw text (never exposed to the recipient; ephemeral,
  // RAW_INPUT_TTL_HOURS expiry) BEFORE calling Gemini, so a raw_input row
  // always exists for whatever was actually sent to the model, even if the
  // Gemini call itself fails.
  const stored = await callServerTx<{ raw_input_id: string; expires_at: string }>(
    serviceClient,
    "server_tx_store_raw_input",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_kind: kindForTarget(targetType as AiDraftTargetType),
      p_raw_text: rawText,
      p_ttl_hours: Number.isFinite(RAW_INPUT_TTL_HOURS) ? RAW_INPUT_TTL_HOURS : 24,
    },
  );

  // 2. Call Gemini. Absolute rule (05_AI_GEMINI.md §8): AI failure must
  // never fall back to sending the raw text — it must throw and let the
  // client fall back to manual entry (typing directly into
  // send-request/create-handover).
  let proposal;
  try {
    proposal = await proposeAiDraft(rawText, targetType as AiDraftTargetType);
  } catch (err) {
    console.error("Gemini proposal failed", { message: err instanceof Error ? err.message : String(err) });
    throw new FamilyOpsError(
      "AI_UNAVAILABLE",
      "AIによる下書き作成に失敗しました。手動で入力してください",
      503,
    );
  }

  // 3. Deterministic fact/quantity/date invariant check
  // (05_AI_GEMINI.md §5 "two-pass validation": model rewrite, then
  // deterministic comparison). A mismatch is rejected outright — never
  // returned to the client as if it were a validated proposal.
  const invariant = validateInvariant(rawText, proposal.sharedText);
  if (!invariant.valid) {
    throw new FamilyOpsError(
      "AI_INVARIANT_VIOLATION",
      "AIの言い換えが元の内容の日付・数量・固有名詞を保持していません",
      422,
      JSON.stringify({ missing_facts: invariant.missingFacts }),
    );
  }

  return jsonResponse({
    raw_input_id: stored.raw_input_id,
    proposed_text: proposal.sharedText,
    warnings: proposal.warnings,
  });
}));

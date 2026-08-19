// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #9A "Configure evening routines".
//
// v6 review fix (P1-4): connects initial household setup -> recurrence ->
// materialization in one transaction, so a fresh household is never left
// with a silently empty night routine (EVENING_ROUTINE_SETUP_REQUIRED /
// docs/design/v6/fixtures/EVENING_SETUP_CASES.json EV01).
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

interface EveningRoutineRow {
  task_code: string;
  weekdays: number[];
  assignee_strategy: "pickup_assignee" | "nonpickup_adult" | "fixed";
  fixed_assignee_id?: string | null;
  scheduled_local_time?: string | null;
  enabled?: boolean;
}

function isValidRow(row: unknown): row is EveningRoutineRow {
  if (typeof row !== "object" || row === null) return false;
  const r = row as Record<string, unknown>;
  if (typeof r.task_code !== "string" || r.task_code.length === 0) return false;
  if (!Array.isArray(r.weekdays) || r.weekdays.length === 0) return false;
  if (!r.weekdays.every((w) => typeof w === "number" && Number.isInteger(w) && w >= 1 && w <= 7)) {
    return false;
  }
  if (!["pickup_assignee", "nonpickup_adult", "fixed"].includes(r.assignee_strategy as string)) {
    return false;
  }
  return true;
}

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const rows = body["rows"];
  if (!Array.isArray(rows) || rows.length === 0 || !rows.every(isValidRow)) {
    throw new FamilyOpsError("INVALID_INPUT", "rows must be a non-empty array of valid evening routine configs", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{
    household_id: string;
    evening_routine_setup_completed_at: string;
  }>(
    serviceClient,
    "server_tx_configure_evening_routines",
    { p_actor_id: actorId, p_operation_id: operationId, p_rows: rows },
  );

  return jsonResponse(result);
}));

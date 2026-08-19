// verify_jwt=true (see supabase/config.toml + EDGE_FUNCTION_AUTH_MATRIX.md).
// WP2: initial dropoff/pickup times and weekly assignee setup — no dedicated
// endpoint exists in the v6 design docs (see the migration's own comment,
// 20260819000018_dropoff_pickup_setup.sql, for why this mirrors
// configure-evening-routines's already-reviewed batch shape instead of the
// WP3 change-recurrence contract). Each row names one (task_code, weekday)
// pair; the batch may cover any subset of the 14 possible
// (dropoff|pickup) x (1..7) combinations — unlike configure-evening-routines
// this is not required to be a complete 7-code batch, since a household may
// reasonably not need dropoff/pickup coverage on every weekday.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

interface DropoffPickupRow {
  task_code: "dropoff" | "pickup";
  weekday: number;
  enabled: boolean;
  fixed_assignee_id?: string | null;
  scheduled_local_time?: string | null;
}

function isValidRow(row: unknown): row is DropoffPickupRow {
  if (typeof row !== "object" || row === null) return false;
  const r = row as Record<string, unknown>;
  if (r.task_code !== "dropoff" && r.task_code !== "pickup") return false;
  if (typeof r.weekday !== "number" || !Number.isInteger(r.weekday) || r.weekday < 1 || r.weekday > 7) return false;
  if (typeof r.enabled !== "boolean") return false;
  return true;
}

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const rows = body["rows"];
  if (!Array.isArray(rows) || rows.length === 0 || !rows.every(isValidRow)) {
    throw new FamilyOpsError(
      "INVALID_INPUT",
      "rows must be a non-empty array of {task_code: 'dropoff'|'pickup', weekday: 1-7, enabled, fixed_assignee_id?, scheduled_local_time?}",
      400,
    );
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<{
    household_id: string;
    dropoff_pickup_setup_completed_at: string;
  }>(
    serviceClient,
    "server_tx_configure_dropoff_pickup",
    { p_actor_id: actorId, p_operation_id: operationId, p_rows: rows },
  );

  return jsonResponse(result);
}));

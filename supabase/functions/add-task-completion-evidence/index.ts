// Q106: optional post-completion evidence. Ordinary complete-task remains the
// one-tap path and does not call this endpoint.
import { createServiceRoleClient, requireUserActor } from "../_shared/auth.ts";
import { withUserMutationHandler, jsonResponse } from "../_shared/handler.ts";
import { callServerTx, readJsonBody, requireOperationId } from "../_shared/rpc.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

const MAX_BASE64_CHARS = 2_800_000;
const ALLOWED_MIME = new Set(["image/jpeg", "image/png", "image/webp"]);

Deno.serve(withUserMutationHandler(async (req: Request) => {
  const actorId = await requireUserActor(req);
  const body = await readJsonBody(req);
  const operationId = requireOperationId(body);

  const taskId = body["task_id"];
  const note = body["note"];
  const image = body["image"] as Record<string, unknown> | null | undefined;
  if (typeof taskId !== "string" || taskId.length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "task_id is required", 400);
  }
  if (note != null && typeof note !== "string") {
    throw new FamilyOpsError("INVALID_INPUT", "note must be a string", 400);
  }

  let mimeType: string | null = null;
  let base64: string | null = null;
  if (image != null) {
    mimeType = typeof image["mime_type"] === "string" ? image["mime_type"] : null;
    base64 = typeof image["base64"] === "string" ? image["base64"] : null;
    if (!mimeType || !base64 || !ALLOWED_MIME.has(mimeType) || base64.length > MAX_BASE64_CHARS) {
      throw new FamilyOpsError("INVALID_INPUT", "image must be JPEG/PNG/WebP and at most 2 MiB", 400);
    }
  }
  if ((typeof note !== "string" || note.trim().length === 0) && !base64) {
    throw new FamilyOpsError("INVALID_INPUT", "note or image is required", 400);
  }

  const serviceClient = createServiceRoleClient();
  const result = await callServerTx<Record<string, unknown>>(
    serviceClient,
    "server_tx_add_task_completion_evidence",
    {
      p_actor_id: actorId,
      p_operation_id: operationId,
      p_task_id: taskId,
      p_note: typeof note === "string" ? note : null,
      p_image_mime: mimeType,
      p_image_base64: base64,
    },
  );
  return jsonResponse(result);
}));

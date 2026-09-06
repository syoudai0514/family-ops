// Issue #54 Concierge proposal surface. This is read-only with respect to
// Family Ops business objects: it authenticates the actor, then reuses the
// exact deterministic LINE conversation parser so PWA and LINE do not grow
// competing semantic rules. Human confirmation happens elsewhere.
import { requireUserActor } from "../_shared/auth.ts";
import { FamilyOpsError } from "../_shared/errors.ts";
import { jsonResponse, withUserMutationHandler } from "../_shared/handler.ts";
import { readJsonBody } from "../_shared/rpc.ts";
import { readOnlyLineIntent } from "../process-line-inbox/lineConversation.ts";
import { deterministicLineConversationCandidates } from "../process-line-inbox/lineMultiIntent.ts";

Deno.serve(withUserMutationHandler(async (req: Request) => {
  await requireUserActor(req);
  const body = await readJsonBody(req);
  const text = body["text"];
  if (typeof text !== "string" || text.trim().length === 0) {
    throw new FamilyOpsError("INVALID_INPUT", "text is required", 400);
  }
  if (text.length > 2000) {
    throw new FamilyOpsError("INVALID_INPUT", "text is too long", 400);
  }

  const readOnlyIntent = readOnlyLineIntent(text);
  if (readOnlyIntent) {
    return jsonResponse({ read_only_intent: readOnlyIntent, candidates: [], clarification: null });
  }

  const candidates = deterministicLineConversationCandidates(text);
  return jsonResponse({
    read_only_intent: null,
    candidates,
    clarification: candidates.length === 0 ? "追加・共有したい内容を、もう少し具体的に教えてください。" : null,
  });
}));

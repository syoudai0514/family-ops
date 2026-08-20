import { corsHeaders, handlePreflight } from "./cors.ts";
import { errorResponse, FamilyOpsError } from "./errors.ts";

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// Wraps a user-facing (verify_jwt=true) function body: handles CORS
// preflight and converts any thrown FamilyOpsError into the normative error
// envelope. Unexpected errors are logged server-side only and returned as a
// generic 500 — no internal detail is ever forwarded to the client.
export function withUserMutationHandler(
  fn: (req: Request) => Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    const preflight = handlePreflight(req);
    if (preflight) return preflight;

    try {
      return await fn(req);
    } catch (err) {
      if (err instanceof FamilyOpsError) {
        return errorResponse(err.code, err.message, err.detail);
      }
      console.error("unhandled edge function error", err);
      return errorResponse("INTERNAL_ERROR", "内部エラーが発生しました");
    }
  };
}

// Wraps a worker/provider (verify_jwt=false) function body. No CORS headers
// (never called from a browser) and no JSON error envelope requirement —
// these are called by cron/webhook infrastructure, not the PWA.
export function withServiceHandler(
  fn: (req: Request) => Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    try {
      return await fn(req);
    } catch (err) {
      if (err instanceof FamilyOpsError) {
        return new Response(JSON.stringify({ error: { code: err.code, message: err.message } }), {
          status: err.httpStatus,
          headers: { "Content-Type": "application/json" },
        });
      }
      console.error("unhandled edge function error", err);
      return new Response(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "internal error" } }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }
  };
}

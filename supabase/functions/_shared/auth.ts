// Edge auth helpers implementing the three classes from
// docs/design/v6/EDGE_FUNCTION_AUTH_MATRIX.md:
//   1. user mutation   (verify_jwt=true)  -> requireUserActor()
//   2. external provider (verify_jwt=false) -> constantTimeEqual() + caller-specific verification
//   3. cron worker     (verify_jwt=false) -> requireWorkerToken()
//
// verify_jwt=false does NOT mean "trusted" — provider/worker handlers must
// authenticate in-handler *before* creating a service-role client or
// touching the database (docs/design/v6/04_SECURITY_RLS_PRIVACY.md
// "v6 Edge gateway requirement").
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { FamilyOpsError } from "./errors.ts";

export function createServiceRoleClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceRoleKey) {
    throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not configured");
  }
  return createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// verify_jwt=true means the Supabase Edge gateway already rejected any
// request with a missing/invalid/expired JWT before this handler runs. We
// still resolve the concrete user via the platform's own verification
// (auth.getUser with the caller's bearer token) rather than trusting an
// unverified decode, and derive household membership from
// public.household_members — never from client-supplied JSON.
export async function requireUserActor(req: Request): Promise<string> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    throw new FamilyOpsError("UNAUTHENTICATED", "認証が必要です", 401);
  }

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anonKey) {
    throw new Error("SUPABASE_URL / SUPABASE_ANON_KEY not configured");
  }

  const client = createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await client.auth.getUser();
  if (error || !data.user) {
    throw new FamilyOpsError("UNAUTHENTICATED", "認証が必要です", 401);
  }
  return data.user.id;
}

// Constant-time string comparison so wrong-length/wrong-content worker
// tokens all take the same time to reject (docs/design/v6/04_SECURITY_RLS_PRIVACY.md #10).
export function constantTimeEqual(a: string, b: string): boolean {
  const aBytes = new TextEncoder().encode(a);
  const bBytes = new TextEncoder().encode(b);
  const maxLen = Math.max(aBytes.length, bBytes.length);
  let diff = aBytes.length === bBytes.length ? 0 : 1;
  for (let i = 0; i < maxLen; i++) {
    const av = i < aBytes.length ? aBytes[i] : 0;
    const bv = i < bBytes.length ? bBytes[i] : 0;
    diff |= av ^ bv;
  }
  return diff === 0;
}

// Handler order per EDGE_FUNCTION_AUTH_MATRIX.md "Worker":
//   1. read X-Family-Ops-Worker-Token
//   2. constant-time compare
//   3. wrong/missing => 401
//   4. only then create service-role client / touch DB
// Callers must call this before createServiceRoleClient()/any DB access.
export function requireWorkerToken(req: Request): void {
  const provided = req.headers.get("X-Family-Ops-Worker-Token") ?? "";
  const expected = Deno.env.get("CRON_WORKER_TOKEN") ?? "";
  // Never log the header value (docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md #15).
  if (expected.length === 0 || !constantTimeEqual(provided, expected)) {
    throw new FamilyOpsError("EDGE_WORKER_UNAUTHORIZED", "worker token invalid", 401);
  }
}

// HMAC-SHA256(channel secret, rawBody) base64 === X-Line-Signature, verified
// on the *raw* request body before any JSON parsing or DB access
// (docs/design/v6/04_SECURITY_RLS_PRIVACY.md #11).
export async function verifyLineSignature(
  rawBody: string,
  signatureHeader: string | null,
): Promise<boolean> {
  if (!signatureHeader) return false;
  const channelSecret = Deno.env.get("LINE_CHANNEL_SECRET") ?? "";
  if (channelSecret.length === 0) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(channelSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody));
  const computed = btoa(String.fromCharCode(...new Uint8Array(signature)));
  return constantTimeEqual(computed, signatureHeader);
}

// AES-256-GCM encryption for the Google Calendar refresh token at rest.
// docs/design/v6/07_GOOGLE_CALENDAR.md #2 "refresh token encrypted
// server-side"; 04_SECURITY_RLS_PRIVACY.md (private schema still assumes
// defense-in-depth for the single most sensitive credential in the system).
//
// New file (not an edit to any existing _shared/*.ts) per this work
// package's collision-avoidance constraints. Deno-native Web Crypto only —
// no external encryption dependency.
//
// GOOGLE_TOKEN_ENCRYPTION_KEY is a real secret that does not exist in this
// dev environment; it is referenced by name only, never fabricated. Expected
// shape: a base64-encoded 32-byte (256-bit) key, e.g. generated with
// `openssl rand -base64 32`. See MANUAL_SETUP_REQUIRED.md.

const ENCRYPTION_VERSION = 1;
const GCM_IV_BYTES = 12; // 96-bit nonce, the AES-GCM standard/recommended size.

function base64Encode(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

function base64Decode(b64: string): Uint8Array {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function loadKey(): Promise<CryptoKey> {
  const keyB64 = Deno.env.get("GOOGLE_TOKEN_ENCRYPTION_KEY");
  if (!keyB64) {
    throw new Error("GOOGLE_TOKEN_ENCRYPTION_KEY not configured");
  }
  const raw = base64Decode(keyB64);
  if (raw.length !== 32) {
    throw new Error("GOOGLE_TOKEN_ENCRYPTION_KEY must decode to exactly 32 bytes (AES-256)");
  }
  return await crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

// Returns a single base64 blob: iv (12 bytes) || ciphertext+tag. The
// encryption_version column lets a future key rotation change the format
// without a backfill migration blocking on it.
export async function encryptRefreshToken(plaintext: string): Promise<{ ciphertext: string; encryptionVersion: number }> {
  const key = await loadKey();
  const iv = crypto.getRandomValues(new Uint8Array(GCM_IV_BYTES));
  const encoded = new TextEncoder().encode(plaintext);
  const cipherBuf = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, encoded);
  const combined = new Uint8Array(iv.length + cipherBuf.byteLength);
  combined.set(iv, 0);
  combined.set(new Uint8Array(cipherBuf), iv.length);
  return { ciphertext: base64Encode(combined), encryptionVersion: ENCRYPTION_VERSION };
}

export async function decryptRefreshToken(ciphertext: string, encryptionVersion: number): Promise<string> {
  if (encryptionVersion !== ENCRYPTION_VERSION) {
    throw new Error(`unsupported google refresh token encryption_version: ${encryptionVersion}`);
  }
  const key = await loadKey();
  const combined = base64Decode(ciphertext);
  const iv = combined.slice(0, GCM_IV_BYTES);
  const cipherBytes = combined.slice(GCM_IV_BYTES);
  const plainBuf = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, cipherBytes);
  return new TextDecoder().decode(plainBuf);
}

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function randomHex(byteLength: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

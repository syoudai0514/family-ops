import { constantTimeEqual, verifyLineSignature } from "./auth.ts";

// Tiny dependency-free assertion helper (avoids relying on jsr.io/deno.land
// reachability, which this environment's network policy does not guarantee).
function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(`assertEquals failed: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

Deno.test("constantTimeEqual: equal strings match", () => {
  assertEquals(constantTimeEqual("abc123", "abc123"), true);
});

Deno.test("constantTimeEqual: different strings do not match", () => {
  assertEquals(constantTimeEqual("abc123", "abc124"), false);
});

Deno.test("constantTimeEqual: different lengths do not match", () => {
  assertEquals(constantTimeEqual("short", "much-longer-string"), false);
});

Deno.test("constantTimeEqual: empty vs non-empty do not match", () => {
  assertEquals(constantTimeEqual("", "nonempty"), false);
});

Deno.test("verifyLineSignature: valid HMAC-SHA256 signature passes", async () => {
  Deno.env.set("LINE_CHANNEL_SECRET", "test-channel-secret");
  const body = '{"events":[{"type":"message"}]}';

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode("test-channel-secret"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  const expected = btoa(String.fromCharCode(...new Uint8Array(sig)));

  assertEquals(await verifyLineSignature(body, expected), true);
});

Deno.test("verifyLineSignature: tampered body fails", async () => {
  Deno.env.set("LINE_CHANNEL_SECRET", "test-channel-secret");
  const body = '{"events":[{"type":"message"}]}';
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode("test-channel-secret"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  const signatureForOriginalBody = btoa(String.fromCharCode(...new Uint8Array(sig)));

  const tamperedBody = '{"events":[{"type":"message","tampered":true}]}';
  assertEquals(await verifyLineSignature(tamperedBody, signatureForOriginalBody), false);
});

Deno.test("verifyLineSignature: missing signature header fails", async () => {
  Deno.env.set("LINE_CHANNEL_SECRET", "test-channel-secret");
  assertEquals(await verifyLineSignature("{}", null), false);
});

Deno.test("verifyLineSignature: missing channel secret fails closed", async () => {
  Deno.env.delete("LINE_CHANNEL_SECRET");
  assertEquals(await verifyLineSignature("{}", "anything"), false);
});

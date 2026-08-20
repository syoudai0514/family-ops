// A fresh operation_id must be minted once per user-initiated action (button
// press, form submit), not per network attempt — client-side retries of the
// same logical action must reuse the same id so the backend's idempotency
// layer collapses them into a single effect. Callers own the "when do I mint
// a new one" decision; this just wraps crypto.randomUUID() for consistency.
export function newOperationId(): string {
  return crypto.randomUUID();
}

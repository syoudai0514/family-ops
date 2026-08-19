# 0004. Google Calendar OAuth start/callback use the design's own state-hash
replay guard, not `private.mutation_receipts`

## Status

Accepted

## Context

Every other `server_tx_*` RPC in this codebase (per WP1's
`20260819000009` convention and every subsequent work package) follows one
fixed idempotency shape: a client-supplied `operation_id` UUID, a
`request_hash` computed from the call's semantic input, and a
claim-then-fill loop against `private.mutation_receipts` keyed by
`(actor_id, operation_id)`.

`docs/design/v6/07_GOOGLE_CALENDAR.md` #2A ("OAuth state/replay") instead
specifies a complete, distinct idempotency/replay mechanism purpose-built
for this one browser-redirect flow:

- a random 256-bit `state`, of which only its SHA-256 `state_hash` is ever
  persisted (`private.google_oauth_states`, already created in WP1's
  `20260819000006` migration);
- a single-use row bound to `user_id`/`household_id`/`return_to` with a 10
  minute TTL;
- the callback locks the row `FOR UPDATE`, checks `used_at is null` and
  `expires_at > now()`, and marks it used in the same transaction that
  consumes it.

This is structurally incompatible with the `operation_id` pattern: Google's
redirect to `google-calendar-oauth-callback` is a `GET` with only
`?code=&state=` query parameters — there is no client-controlled JSON body
to carry an `operation_id`, and the request is not authenticated by a JWT at
all (per #2A step 4, "stored user/household binding is authoritative"), so
there is no `actor_id` to key `private.mutation_receipts` on either.

## Decision

`server_tx_start_google_oauth` / `server_tx_complete_google_oauth`
(`supabase/migrations/20260819000050_google_oauth_rpcs.sql`) do not touch
`private.mutation_receipts` at all. Replay/idempotency protection is
provided entirely by `private.google_oauth_states`'s own single-use +
TTL + `FOR UPDATE` mechanics, exactly as #2A specifies. Every other WP7
RPC that *is* a normal client-invoked JSON mutation
(`server_tx_classify_calendar_busy`) still follows the standard
`operation_id`/`mutation_receipts` pattern.

`private.google_write_operations` (WP1, used by
`server_tx_claim_google_write`/`server_tx_finalize_google_write` in
`20260819000056`) plays the same "claim before doing anything remote, fill
after" role as `mutation_receipts` for create/update Calendar writes, but is
its own purpose-built table (per #11 "`private.google_write_operations`
claimed before provider call") because it also has to carry the resulting
Google event id and result etag, which `mutation_receipts`'s generic
`result_payload jsonb` could technically hold but the dedicated table makes
directly queryable/indexable (`UNIQUE(calendar_connection_id,
google_event_id)`).

## Consequences

- `google-calendar-oauth-start` and `google-calendar-oauth-callback` are the
  only two Edge Functions in the Google Calendar work package with no
  `operation_id` in their request contract at all.
- A human reviewing "does every mutation have an operation_id?" against
  `18_MUTATION_CONTRACT_MATRIX.md` should treat these two as an intentional,
  documented exception, not a missed requirement.

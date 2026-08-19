# 0003. A new `propose-ai-draft` endpoint fills a real v6 gap

## Status

Accepted

## Context

`docs/design/v6/10_WORK_PACKAGES.md`'s WP5 line item requires a
`free_lightweight` Gemini parser/rewrite flow with fact/quantity/date
invariant validation and manual fallback. `18_MUTATION_CONTRACT_MATRIX.md`
§13 ("AI rewrite confirmation") explicitly names the two endpoints that
consume a confirmed draft — `confirm-request-draft` / `confirm-handover-draft`
— and states the contract precisely: "AI preview itself is not business
mutation," "author must confirm transformed text," "shared row created only
after confirmation," "recipient never sees private raw text."

Exhaustive review of the vendored v6 design package — `05_AI_GEMINI.md`
(the full AI contract), `09_API_AND_EDGE_FUNCTIONS.md`, the full 52-function
`docs/design/v6/supabase/config.toml` snapshot, and
`18_MUTATION_CONTRACT_MATRIX.md` in full — found no named endpoint for the
*first* half of the flow: submitting raw text, storing it in
`private.raw_inputs`, invoking Gemini, and returning the parsed/rewritten
proposal for the user to review *before* confirmation. `05_AI_GEMINI.md` §7
describes the shape (`parse -> pending_action -> preview -> confirm ->
durable execution worker -> atomic business transition`) but names no
endpoint for the parse/preview step, and the 52-function matrix has no
AI-shaped entry at all.

Per ADR 0001, this repository does not draft a new design (no v7) and does
not treat the implementation as free to invent scope beyond what a genuine
gap requires.

## Decision

Add one new Edge Function, `propose-ai-draft`
(`supabase/migrations/20260819000028_raw_inputs_ai_draft_support.sql`),
that accepts raw text plus a `target_type` of `'request'` or `'handover'`,
stores the raw text in `private.raw_inputs` (already a v5-exact table per
`03_DOMAIN_AND_DATA_MODEL.md`, migrated in
`20260819000006_private_queues_tokens.sql`), calls Gemini via
`supabase/functions/_shared/gemini.ts`, runs the fact/quantity/date
invariant check, and returns the proposal without writing to `requests`/
`handovers`. It is parameterized by `target_type` (one function, not a
`propose-request-draft`/`propose-handover-draft` split) because nothing in
the design distinguishes the *parse/preview* step by target — the split
`confirm-request-draft`/`confirm-handover-draft` naming in
`18_MUTATION_CONTRACT_MATRIX.md` §13 exists because those two endpoints
write to two different tables with different columns; `propose-ai-draft`
writes to neither, so one endpoint suffices.

`confirm-request-draft` and `confirm-handover-draft` use the exact names
`18_MUTATION_CONTRACT_MATRIX.md` §13 already specifies — no gap there.
Their server-side logic (`server_tx_confirm_request_draft` /
`server_tx_confirm_handover_draft`) validates the raw_input's ownership/
household/expiry, then calls the already-implemented, already-reviewed
`public.server_tx_send_request` / `public.server_tx_create_handover`
(WP2) under a *derived* sub-operation-id
(`md5(p_operation_id::text || ':server_tx_send_request')::uuid`) rather than
re-implementing their insert logic — this keeps one authoring path for
`requests`/`handovers` rows. The derivation is necessary, not cosmetic:
`private.mutation_receipts` primary-keys on `(actor_id, operation_id)` alone
(no `action_type` in the key), so calling the inner function with the
caller-supplied `p_operation_id` unchanged would collide with the outer
confirm function's own claim row on the very first call.

`scripts/check-edge-auth-matrix.mjs` will need `propose-ai-draft`,
`confirm-request-draft`, and `confirm-handover-draft` added to its
`GAP_FILL_FUNCTIONS` allowlist (mirroring `configure-dropoff-pickup`'s
existing entry) — not done in this change, since the task instructions for
this work package direct that `supabase/config.toml` and
`scripts/check-edge-auth-matrix.mjs` are edited by the maintainer, not this
agent.

## Consequences

- If a future revision of the vendored design names a `propose-*` endpoint
  explicitly (split by target or otherwise), retiring/renaming
  `propose-ai-draft` is a deliberate follow-up decision (its own ADR entry),
  not a silent rename.
- `AI_INVARIANT_VIOLATION` (thrown directly from the Edge Function, not
  raised in PL/pgSQL) and `RAW_INPUT_EXPIRED` / `AI_UNAVAILABLE` are new
  error codes this change needs; they are not registered in
  `supabase/functions/_shared/errors.ts` by this change (also maintainer
  territory per this task's instructions) — until registered,
  `RAW_INPUT_EXPIRED` raised from PL/pgSQL is downgraded to a generic
  `INTERNAL_ERROR` (500) by `_shared/rpc.ts`'s `isKnownErrorCode` gate, and
  `AI_INVARIANT_VIOLATION` / `AI_UNAVAILABLE` (thrown directly as
  `FamilyOpsError` in the Edge Function, bypassing that gate) return their
  correct code but a 500 status until `HTTP_STATUS_BY_CODE` is populated.
- No other WP5 endpoint follows this pattern — `confirm-request-draft` and
  `confirm-handover-draft` are named, normative-matrix members already.

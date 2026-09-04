# PR #44 — DD9 pre-review scope-boundary hardening

This addendum follows the temporal covert-channel remediation at historical integrated head `6017bc08fc72c249a78bcb2580984901321d7a4c`.

The primary remediation remains `20260904000004_dd9_pre_review_temporal_grounding_minimization.sql` plus SQL #56: R0 has no reviewed trusted temporal-token inventory, so caller/model temporal scalars are removed from pre-review durable structured data and the 128-byte / 64-date reversible channel no longer survives persistence.

A follow-up boundary sweep found one defense-in-depth gap in the first table guard: `private.document_facts` minimized only when the referenced extraction already matched the row household/test scope. A privileged writer could otherwise attempt to modify the hostile structured value and its scope columns in the same statement so that a conditional guard would not recognize the row as extraction-backed. `public.change_candidates` had the analogous provenance concern if an existing nursery candidate were relabeled while its patch was changed.

## Final hardening

Migration:

- `supabase/migrations/20260904000005_dd9_pre_review_scope_fail_closed.sql`

Behavior:

- every `private.document_facts` INSERT/UPDATE must resolve its NOT NULL `extraction_id` and match the extraction household/test scope before the v3 fact minimizer runs;
- a mismatched fact lineage fails closed with `NURSERY_DOCUMENT_FACT_SCOPE_MISMATCH`;
- an `ai_inference` candidate whose `source_ref` resolves to a nursery extraction must use the same household/test scope;
- once a candidate is recognized as a nursery pre-review candidate, household/source type/source ref/test-context provenance cannot be changed to evade the nursery minimizer;
- target ID and current snapshot hash remain NULL and the temporal/free-text/technical minimizers still run for recognized nursery candidates.

Regression:

- `tests/sql/57_dd9_pre_review_scope_guard.sql`

SQL #57 starts from the ordinary intake -> review path, then attempts same-statement scope/provenance changes together with temporal values under `service_role`. The writes must fail closed and the original durable rows must remain minimized.

## Activation boundary

This remains source-readiness only. PR #44 stays Draft/open/unmerged until a fresh independent integrated source review returns GO. No September 2026 migration is production-applied by this work; no P1 activation, Edge production deployment, real LINE delivery, or new Google provider mutation is authorized.
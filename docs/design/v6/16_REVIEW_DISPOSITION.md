# 16. v3 SOL Review Disposition — v6

Source:
- `review/FAMILY_OPS_V3_SOL_REREVIEW_2026-08-19.md`
- `review/SONNET_V4_REVISION_REQUEST_2026-08-19.md`

Result was REQUEST CHANGES / P0 0 / P1 10 / P2 8 / P3 3.

## P1

1. Google nullable deleted/cancelled/untitled -> **FIXED**
2. Google create idempotency undecided -> **FIXED: deterministic client-generated ID**
3. google_sync_jobs failed ambiguity -> **FIXED: queued/processing/done/dead**
4. RPC/Edge boundary ambiguous -> **FIXED: Edge-only client entry + server-only RPC**
5. Cron worker auth -> **FIXED: CRON_WORKER_TOKEN**
6. Core mutation contracts missing -> **FIXED: 18_MUTATION_CONTRACT_MATRIX.md**
7. PWA mutation idempotency missing -> **FIXED: mutation_receipts**
8. Google credential household binding -> **FIXED: composite FK**
9. recurrence lacks time -> **FIXED: scheduled_local_time/conflict_window**
10. busy attribution creator misuse -> **FIXED: busy member table + metadata + transparency**

## P2

1. OAuth Testing 7-day -> **FIXED in setup/runbook**
2. subtask/handover same-household -> **FIXED with household_id composite FK**
3. creator_mapped same-household -> **FIXED composite FK**
4. notification dedup scope -> **FIXED recipient/channel**
5. request cancelled -> **FIXED requester pending-only**
6. shopping lifecycle -> **FIXED**
7. all-day busy setting not modeled -> **FIXED: always ignored MVP**
8. special_preparations pseudo seed -> **FIXED normalized task/recurrence**

## P3

1. ON DELETE choices -> **FIXED RESTRICT + deactivate/history preservation**
2. recurrence overlap choices -> **FIXED btree_gist exclusion**
3. invalid watch response -> **FIXED 2xx ignore + warning**
4. token cleanup choice -> **FIXED hard delete after retention**

## User additions after v3 review

Also included as first-class requirements:
- Sunday weekly LINE digest
- 07:00 daily assignment
- dropoff checklist/check-in
- pickup checklist/check-in
- non-pickup evening checklist/check-in
- LINE/PWA dual input
- same-minute bundling
- check-in reminder suppression
- schedule customization
- reassignment-aware session invalidation

## Gate

WP0 GO.
WP1 HOLD until independent v6 SOL returns P0=0/P1=0.

## v4 -> v6 independent review disposition

Latest independent review: `review/FAMILY_OPS_V4_SOL_REREVIEW_2026-08-19.md`
Result: REQUEST CHANGES, P0 0 / P1 8 / P2 7 / P3 3.

v6 disposition:
- P1-1 LINE 200 quota: FIXED with provider-aware hard budget, soft 180/reserve20, fallback and reply preference.
- P1-2 LINE persistent mapping: FIXED with private.line_user_links.
- P1-3 missing private schemas: FIXED exact columns/constraints in 03/15.
- P1-4 private RPC transport contradiction: FIXED public.server_tx_* service_role-only.
- P1-5 household setup contracts: FIXED in 18.
- P1-6 OAuth state: FIXED exact table/single-use flow, confidential web-server + state, no PKCE MVP.
- P1-7 Google sync/projection/staging: FIXED exact query snapshots and staging schema; no local RRULE parser.
- P1-8 busy member FK hole: FIXED triple composite FK.

P2/P3:
- timezone fixed Asia/Tokyo
- queue/write retention fixed
- backup health cron removed
- Google scopes exact
- persistent busy classification added
- auth/member hard delete unsupported
- max adults=2 enforced transactionally
- ordinary tombstone=30d
- weekly preflight uses worker_run_receipts
- dispatch_slot_key and same-day edit semantics fixed


## v5 -> v6 independent review disposition

Latest:
`review/FAMILY_OPS_V5_SOL_REREVIEW_2026-08-19.md`

Result: REQUEST CHANGES / P0 0 / P1 8 / P2 8 / P3 2.

P1 disposition:
1. Edge auth matrix/config — FIXED
2. Google recurring identity — FIXED
3. Busy classification DB/RLS normalization — FIXED
4. Evening recurrence setup — FIXED
5. LINE retry 24h — FIXED
6. Atomic quota + app hard cap 200 — FIXED
7. Google writable target/PATCH contract — FIXED
8. webhook provider_event_id DDL typo — FIXED

P2/P3:
- durable notification history
- 429 distinction
- A→B→A session reuse
- one dispatch uniqueness
- sendUpdates none
- Asia/Tokyo target
- R2 Standard
- Edge invocation telemetry
- source snapshot refreshed

Additional user rule:
- weekends/holidays 09:00 + 20:00
- Sunday 09:00 bundles next week

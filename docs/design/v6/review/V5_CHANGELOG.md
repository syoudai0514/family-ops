# V5 CHANGELOG — 2026-08-19

Source: v4 independent SOL review `P0 0 / P1 8 / P2 7 / P3 3`.

## P1 fixes
1. LINE Communication Plan monthly quota budget added.
2. Permanent LINE identity mapping (`private.line_user_links`) added.
3. Exact schemas restored for webhook/pending/raw/invite/link/OAuth/outbox private tables.
4. Edge transaction RPC transport fixed to `public.server_tx_*`, service_role only.
5. Household create/invite/join mutation contracts fixed, adult max=2.
6. Google OAuth state single-use storage/replay contract added; PKCE choice removed (MVP no PKCE).
7. Google canonical sync, 410 staging and rolling projection exact query contract fixed; local RRULE parser prohibited.
8. Busy-member occurrence FK closed with household+calendar+occurrence triple.

## P2/P3 fixes
- Asia/Tokyo fixed MVP.
- Exact retention horizons.
- backup-health Supabase Cron removed; GitHub Actions self-verifies R2 object.
- exact Google scopes.
- persistent manual busy classification.
- auth user/member hard delete unsupported.
- ordinary deleted tombstone 30d.
- worker_run_receipts for weekly preflight.
- dispatch_slot_key exact and same-day schedule edit semantics fixed.

## New fixtures
- LINE_QUOTA_CASES.json
- LINE_LINK_CASES.json
- exact Calendar query contract fixture
- household/OAuth idempotency/token cases

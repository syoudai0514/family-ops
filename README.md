# family-ops

家族の予定・家事・お願い・買い物・引き継ぎを共有する家庭運営OS。
設計正本は [`docs/design/v6/`](docs/design/v6/README.md)（`family-ops-sonnet-plan-v6`）。v1〜v5は実装判断に使用しない。

## Stack

- **Frontend**: React + TypeScript + Vite, PWA (installable on iPhone home screen)
- **Backend**: Supabase (Postgres + Auth + Edge Functions), Tokyo region, Free plan
- **Calendar of record**: Google Calendar (shared family calendar)
- **Daily interaction**: LINE Messaging API (free tier, hard-capped at 200 counted
  messages/month — see `docs/design/v6/06_LINE_INTEGRATION.md` and
  `17_ROUTINE_LINE_AUTOMATION.md`)
- **AI**: Google Gemini free tier (natural-language parsing / rewrite only)

## Repository layout

```
apps/web/                  React + TS + Vite PWA
supabase/
  config.toml              Supabase project config incl. Edge Function verify_jwt matrix
  migrations/               SQL migrations (schema, RLS, grants, server_tx_* RPCs)
  functions/                Edge Functions (Deno)
    _shared/                 auth/cors/idempotency helpers shared across functions
docs/design/v6/             Vendored copy of the v6 design package (normative)
tests/
  sql/                       psql-driven schema/RLS/RPC/idempotency/quota tests
  unit/                      misc non-web unit tests
scripts/                     Dev/CI helper scripts
.github/workflows/ci.yml    CI: web (lint/typecheck/test/build), db (migrations+SQL tests),
                             edge-functions (deno lint/check + auth-matrix lint)
```

## Prerequisites

- Node.js `^22.22.2 || ^24.15.0 || >=26.0.0` (matches `package.json` engines and
  the strictest transitive dependency requirement — jsdom 30.0.1; CI pins
  `node-version: 22.22.2`)
- PostgreSQL 16 client + server binaries (`psql`, `initdb`, `pg_ctl`) for local
  migration/RLS/RPC testing without a hosted Supabase project
- [Deno](https://deno.com/) 2.x for Edge Function lint/typecheck
- A Supabase project (Tokyo region, Free plan) for actual deployment — see
  `docs/design/v6/14_EXTERNAL_SETUP_STEPS.md`

## Getting started (web app)

```bash
cd apps/web
cp .env.example .env.local   # fill in VITE_SUPABASE_URL / VITE_SUPABASE_PUBLISHABLE_KEY
npm install
npm run dev
```

Root-level convenience scripts (run from repo root):

```bash
npm install          # installs workspace deps (apps/web)
npm run lint          # apps/web lint (oxlint)
npm run typecheck     # apps/web typecheck (tsc -b)
npm run test          # apps/web unit tests (vitest)
npm run build          # apps/web production build
npm run test:sql       # DB migrations + RLS/RPC/idempotency/quota SQL test suite
```

## Database / Edge Functions

`supabase/config.toml`'s `[functions.*]` block is a **live deployment
snapshot** — one entry per function actually implemented under
`supabase/functions/` (currently 6). The full 52-function v6 design matrix
lives at `docs/design/v6/EDGE_FUNCTION_AUTH_MATRIX.md` /
`docs/design/v6/supabase/config.toml` and is not required to be mirrored
1:1 into the live config as work packages add functions —
`scripts/check-edge-auth-matrix.mjs` lints the two independently: design-matrix
completeness on its own, and (separately) that every deployed function has a
correctly-classified live entry and the live config declares nothing beyond
what's deployed. Each function is classified into exactly one of:

1. **user mutation** (`verify_jwt = true`) — actor identity comes from the
   Supabase JWT `sub`.
2. **external provider** (`verify_jwt = false`) — LINE webhook signature /
   Google Calendar watch channel / Google OAuth state validated in-handler
   before any DB access.
3. **cron worker** (`verify_jwt = false`) — `X-Family-Ops-Worker-Token`
   constant-time compared before any DB access.

Browsers never call `private` schema tables or `public.server_tx_*` RPCs
directly — those are `SECURITY INVOKER`, `EXECUTE` is revoked from
`PUBLIC/anon/authenticated`, and only `service_role` (used exclusively from
Edge Functions) can call them. See `docs/design/v6/04_SECURITY_RLS_PRIVACY.md`
and `15_DDL_CONTRACT.md`.

Edge Functions never touch `private.webhook_inbox` or
`private.notification_outbox` via the Data API `.from()` client, even under
`service_role` — they go through `public.server_tx_ingest_line_webhook_event`
and `public.server_tx_count_queued_notifications`. `private` is not in
`[api] schemas`, so a Data API call would 404 against a real project anyway,
but the RPC boundary is enforced by convention regardless of that config, per
`docs/design/v6/15_DDL_CONTRACT.md` #8.

See `docs/RUNBOOK.md` for operational safety notes, including why an
`auth.users` row must never be hard-deleted from the Supabase Dashboard once
the household has any history.

### Google Sign-In (local dev)

Family Ops' only onboarding path is Supabase Auth's own Google provider
(`docs/design/v6/01_ARCHITECTURE.md`) — separate from the Google Calendar
OAuth client used by `google-calendar-oauth-start`/`-callback`. Two distinct
URLs are involved and must not be conflated:

1. **Google → Supabase Auth (GoTrue) callback** — `redirect_uri` in
   `supabase/config.toml`'s `[auth.external.google]`, sourced from
   `GOOGLE_SIGNIN_CALLBACK_URL`. For the local Supabase CLI stack this is
   fixed: `http://127.0.0.1:54321/auth/v1/callback`. Register this exact
   URL in the Google Cloud Console's OAuth client "Authorized redirect
   URIs".
2. **App's own post-login redirect** — the PWA's landing page after GoTrue
   finishes the exchange, passed as `redirectTo` by the client SDK at
   sign-in time and validated against `[auth] site_url` /
   `additional_redirect_urls` in `supabase/config.toml` (already
   `http://localhost:5173` for local dev). This is never read from `.env`.

The project-root `.env` (copy from `.env.example`, never commit it — it's
gitignored) is the single source of truth for values `supabase/config.toml`
reads via `env(...)`. `supabase` does not load a dotenv file on its own, so
export it explicitly before any CLI command:

```bash
cp .env.example .env   # fill in GOOGLE_SIGNIN_CLIENT_ID/SECRET
set -a && source .env && set +a
supabase start
```

### Running the SQL test suite locally

No Docker/Supabase CLI is required for the migration/RLS/RPC test suite — it
runs against a plain local PostgreSQL 16 cluster and reproduces the minimal
pieces of Supabase's `auth`/`anon`/`authenticated`/`service_role` contract
needed to exercise RLS and function grants (see
`tests/sql/00_local_auth_shim.sql`, which is a **test-only** shim and is never
applied to a real Supabase project, since Supabase already provides those
roles/functions).

```bash
npm run test:sql
# or directly:
bash scripts/run_sql_tests.sh
```

## Work packages

Implementation proceeds through the work packages defined in
`docs/design/v6/10_WORK_PACKAGES.md`. This repository currently implements:

- **WP0** — repo/app bootstrap, PWA, Supabase client wiring, lint/typecheck/test, CI
- **WP1** — core schema, RLS, private schema, `server_tx_*` mutation boundary,
  household create/invite/join, mutation idempotency, LINE/Google/routine/holiday
  schema foundation

See the top-level implementation report (posted alongside the PR) for exact
test evidence and what remains for WP2+.

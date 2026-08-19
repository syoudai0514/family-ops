# CONTINUATION — Family Ops v6 implementation

Written because this session is near its usage limit (resets 18:10 UTC on
2026-08-19). This file is the single source of truth for resuming work. Read
it fully before doing anything else.

## 1. Current HEAD commit hash

```
fb8ec3b6b5b32f099252133ebf4066330d83d20c1
```
(branch `claude/family-ops-v6-implementation-6x4mft`, already pushed to
`origin` — confirmed identical to `origin/claude/family-ops-v6-implementation-6x4mft`.)

**CI status for this commit: ALL GREEN.** PR #1
(`syoudai0514/family-ops#1`), all 4 required checks `success`:
- `db (migrations / RLS / RPC / idempotency / quota)`
- `web (lint / typecheck / test / build)`
- `edge-functions (deno lint / check / auth-matrix lint)`
- `supabase-integration (real CLI stack)`

Do NOT push anything to `main` — this branch only, per standing instructions.

## 2. Completed work packages (backend unless noted)

All committed and pushed to the branch above, in this commit order:

| Commit | WP | Summary |
|---|---|---|
| (earlier session, see `git log`) | WP0 | Vite+React+TS+PWA scaffold, CI, env template |
| `a165860` | WP1 review fixes | canonical task bootstrap, Asia/Tokyo evening setup, LINE quota threshold, real-stack CI, Google Sign-In callback split |
| `2b65d57` | — | pin `db.major_version=17` for Supabase CLI 2.115.0 |
| `f9e135c` | WP2 prep (P2) | `recurrence_rules_no_overlap` concurrency test (MI-RR01), LINE redelivery runbook |
| `e7a7a9a` | **WP2** | full manual PWA: Today/household setup/task/request/shopping/handover/notifications backend (16 `server_tx_*` RPCs, 24 Edge Functions) + entire `apps/web/` frontend |
| `153c4af` | **WP10** | backup/recovery infra — daily encrypted dump, R2 upload, restore drill |
| `a48fcc1` | **WP3** | recurrence engine — `change-recurrence`, `reassign-task-once`, role-based assignee resolver, MI-RR02 concurrency test |
| `0858582` | **WP5** | Gemini AI-draft — `propose-ai-draft`, `confirm-request-draft`, `confirm-handover-draft`, invariant-check unit tests (44/44) |
| `b236162` | **WP6** | LINE foundation — `create-line-link-token`, `unlink-line-account`, `process-line-inbox` (NL grammar + postback handling), `process-pending-actions`, lease/reclaim/dead-letter on both queues |
| `f1f5bc9` | **WP7** | Google Calendar — full OAuth/watch/sync-queue/canonical-sync/projection/writes (10 Edge Functions), AES-256-GCM token encryption |
| `fb8ec3b` | CI fix | `cryptoHelper.ts` failed `deno check` under CI's pinned Deno 2.9.5/TypeScript 6.0.3 (stricter typed-array generics than this dev environment's previously-installed 2.1.4). Fixed with an explicit `toArrayBuffer()` copy before every `crypto.subtle.*` call. **Verified by upgrading this environment's own `deno` to 2.9.5 and reproducing + confirming the fix against the exact CI toolchain** (this environment's `deno --version` is now permanently 2.9.5 — use it for all future `deno check`/`deno lint` verification, don't trust an older local Deno). |

Both WP3+WP5 and WP6+WP7 batches also included a **consolidation pass**
(same commits) that centrally added their `[functions.*]` entries to
`supabase/config.toml` and their error codes to
`supabase/functions/_shared/errors.ts` — this consolidation step is a
required part of finishing any future parallel-agent batch too (see
"Concrete next steps" below).

Also present (not itself a WP, but load-bearing): `docs/adr/0001` through
`0005` documenting every genuine v6-design gap filled so far
(`configure-dropoff-pickup`, `propose-ai-draft`/`confirm-request-draft`/
`confirm-handover-draft`, the OAuth-state-not-mutation-receipt decision, the
temporary WP7 error-code split later folded into `errors.ts`). Read
`docs/adr/README.md` for the index.

## 3. In-progress work packages and their actual state

**WP8 (scheduled LINE routine dispatcher), WP9 (notification delivery +
fatigue audit), WP4 (realtime/history frontend)**: three background agents
were launched in parallel for these. **All three failed immediately on the
session usage limit** ("You've hit your session limit · resets 6:10pm
(UTC)") before writing any files — confirmed via `git status --short`
showing zero changes at the time of failure. **Effective progress on all
three: 0%.** There is nothing to reconcile or clean up; they need a full
fresh start, not a resume.

The prompts used to launch them are reconstructable from this session's
transcript, but see "Concrete next steps" below for a corrected version
(launch fewer agents per batch this time).

## 4. Incomplete work

- **WP4** — realtime partner sync, planned-vs-actual history view, handover
  unread indicator, Today refresh after partner mutation. Not started.
- **WP8** — `dispatch-routine-automation`, `get-routine-session`,
  `complete-routine-session`, `routine-session-item-action`, PWA
  `/checkin/:sessionId`. Not started. Implements
  `docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md` "exactly" per
  `10_WORK_PACKAGES.md`.
- **WP9** — notification UX/fatigue audit. Not started. Includes a real
  scope item flagged by WP6: **`send-notifications`'s actual LINE push-send
  loop was never built** (only the WP1-era auth-boundary stub is deployed).
  This blocks any real outbound LINE delivery, including WP8's routine
  check-in prompts and WP5's AI-draft confirm/cancel quick-replies. This is
  the single most functionally-impactful remaining gap.
- **WP11** — production readiness runbooks (iPhone PWA E2E, Supabase Free
  pause/recovery, Calendar OAuth production, LINE/Gemini quota & fallback,
  cron worker token rotation, dead-letter runbook, Google webhook
  convergence, watch renewal, cleanup, scheduled-notification
  timezone/idempotency, backup freshness). Not started.
- **WP12** — final self-review, full test suite run, CI green, review ZIP,
  10-item final report. Not started (this file exists specifically so WP12
  can eventually be completed correctly).
- **Remaining normative-matrix gaps** (from `docs/design/v6/supabase/config.toml`'s
  52-function list vs. what's deployed — 49/52 currently deployed): still
  missing `dispatch-routine-automation`, `get-routine-session`,
  `complete-routine-session`, `routine-session-item-action` (all WP8),
  `sync-jp-holidays`, `cleanup-expired-private-data` (utility crons, WP1-era
  scope never built — assign to WP8/WP9 batch or WP11, whichever agent picks
  them up first — flag this explicitly so nobody assumes they're done),
  `materialize-recurring` (the underlying `private.materialize_recurrence_rule`
  SQL function already exists and is used internally; only a dedicated
  Edge Function *wrapper* for it, if the design actually wants one exposed
  standalone, is missing — verify against the design doc before building,
  it may not need one).
- **MANUAL_SETUP_REQUIRED.md** already has LINE (WP6) and Google Calendar
  (WP7) sections. WP8/WP9 will need to append their own sections (worker
  scheduling for `dispatch-routine-automation`, and confirming
  `LINE_CHANNEL_ACCESS_TOKEN`'s actual runtime use once `send-notifications`
  is completed).

## 5. Concrete next steps (in order)

1. **Wait for the session limit to reset** (18:10 UTC 2026-08-19) or resume
   in a fresh session/container reading this file first.
2. **Relaunch WP8, WP9, WP4 — but not all three at once.** Three parallel
   agents hit the limit together twice in this session already (once for a
   5-agent batch, once for this 3-agent batch). Launch **one or two at a
   time** instead, e.g. WP9 alone first (it's the highest-impact gap —
   `send-notifications`'s push loop blocks WP8's own usefulness), verify and
   commit it, then WP8, then WP4. Each agent prompt should reiterate:
   read `docs/design/v6/` sections relevant to its own WP only, never edit
   `docs/design/v6/`, never edit `supabase/config.toml` /
   `scripts/check-edge-auth-matrix.mjs` / `supabase/functions/_shared/errors.ts`
   directly (report needed entries instead), stay inside its own
   file/directory/migration-number range, don't commit/push (the
   orchestrating session does that), and — new for this round — **explicitly
   tell each agent "be economical with tool calls and context; a previous
   parallel batch failed on a session usage limit."**
3. **After each agent completes**, independently verify before trusting its
   report:
   - `deno lint` and `deno check` on every new/modified Edge Function — this
     environment's `deno` is now pinned to 2.9.5 (matching CI exactly), so
     trust its result over any different version.
   - `PGHOST=127.0.0.1 PGPORT=5544 PGUSER=postgres bash scripts/run_sql_tests.sh`
     (the local Postgres 16 harness should still be running on port 5544 —
     check with `pg_isready -h 127.0.0.1 -p 5544`; if it's gone, whatever
     originally started it needs to be restarted before tests can run).
   - For any frontend changes: `cd apps/web && npm run typecheck && npm run
     lint && npm test -- --run`.
4. **Consolidate shared-file edits centrally** (same pattern as every prior
   round): add reported `[functions.*]` entries to `supabase/config.toml`,
   new error codes to `supabase/functions/_shared/errors.ts`, any
   `EDGE_FUNCTIONS` entries to `apps/web/src/lib/edgeFunctions.ts`, and wire
   any reported new frontend routes into `apps/web/src/app/AppShell.tsx`
   (agents were instructed NOT to edit this router file themselves, to avoid
   a 3-way collision — their final reports should each state the exact route
   path + component name needed). Re-run `node
   scripts/check-edge-auth-matrix.mjs` after the config.toml edit.
5. **Commit one commit per WP** (established pattern — see the table above
   for commit-message style/detail level to match), **push after every
   commit** (`git push -u origin claude/family-ops-v6-implementation-6x4mft`),
   and **check PR #1's CI status after every push** (`get_check_runs` via
   the GitHub MCP tools, or watch for the `check_run.completed` wake event —
   this session was already subscribed to PR #1's activity). Fix red CI
   immediately per the drive-to-green rules — the `cryptoHelper.ts` Deno
   version issue in this session shows new Google/LINE code can trip
   CI-vs-local toolchain drift even when local checks look clean; the fixed
   local `deno` version (2.9.5) should prevent a repeat, but stay alert.
6. Once WP8/WP9/WP4 are done, verified, and green: **WP11** (production
   readiness runbooks — mostly documentation plus a few small verification
   scripts, lower risk than the earlier backend WPs) then **WP12** (final
   pass — see below).
7. **WP12 checklist** (do this yourself, not via a sub-agent, since it's a
   synthesis/verification task over the whole repo): re-run every test
   suite one more time all together (SQL + concurrency + deno + frontend),
   confirm CI green on the final commit, do a self-review pass reading back
   through `docs/adr/*` and this file's "Incomplete work" section to confirm
   nothing was silently dropped, rebuild the review ZIP (see the WP2-era
   ZIP-building approach from earlier in this session for the
   exclude-list: `node_modules`, `.git`, build output, no secrets), and
   produce the user's requested 10-item final report (commit hash,
   implemented-WP list, feature list, migrations, Edge Functions, test
   results, CI results, manual-setup items, outstanding items, review ZIP).

## 6. Uncommitted / unpushed changes

**None.** `git status --short` is empty. `HEAD` (`fb8ec3b`) is identical to
`origin/claude/family-ops-v6-implementation-6x4mft`. Nothing is at risk.

## 7. Tests executed and results (as of `fb8ec3b`)

- **Local SQL suite** (`tests/sql/00_local_auth_shim.sql` through
  `20_google_calendar.sql`, 21 files) + **all 5 true-parallel concurrency
  races** (MI-HH03 join race, M-01 double-tap, LQA01/LQA02 LINE quota,
  MI-RR01 raw-insert recurrence overlap, MI-RR02 RPC-path recurrence
  overlap): **all PASS**, run via
  `PGHOST=127.0.0.1 PGPORT=5544 PGUSER=postgres bash scripts/run_sql_tests.sh`
  against the local Postgres 16 harness at `/tmp/famops_pgdata`.
- **`deno lint`** across the full `supabase/functions/` tree (60 files):
  clean.
- **`deno check`** on all 49 currently-deployed Edge Functions, run against
  CI's exact Deno 2.9.5 / TypeScript 6.0.3 (this environment's Deno was
  upgraded specifically to reproduce and confirm-fix the CI failure): clean.
- **`node scripts/check-edge-auth-matrix.mjs`**: passes — 52-function
  normative design matrix confirmed intact and unedited; live
  `supabase/config.toml` declares exactly 49 deployed functions, each with
  the correct `verify_jwt` classification (3 remaining normative functions
  not yet deployed are WP8/utility-cron scope, tracked in section 4 above).
- **Frontend** (`apps/web`, as of WP2 — not touched since, so unchanged):
  `npm run typecheck` clean, `npm run lint` (oxlint) clean aside from
  pre-existing P2/P3-level warnings (`set-state-in-effect`,
  `only-export-components` — not blocking, noted but not fixed per the
  "don't stop for P2/P3" instruction), `npm test -- --run` 17/17 passing.
- **`deno test` on `_shared/gemini.test.ts`**: 44/44 invariant-check unit
  tests passing (no live Gemini calls).
- **GitHub Actions CI on PR #1, commit `fb8ec3b`**: all 4 jobs green
  (`db`, `web`, `edge-functions`, `supabase-integration`) — confirmed via
  the GitHub API just before this file was written.

## 8. Manual setup required (human action, tracked in `MANUAL_SETUP_REQUIRED.md`)

Full detail lives in `MANUAL_SETUP_REQUIRED.md` at the repo root (already
committed). Summary:

**LINE (WP6):**
- LINE Developers console: Messaging API channel, webhook URL pointed at
  the deployed `line-webhook-receiver` function, "Use webhook" enabled.
- Supabase secrets: `LINE_CHANNEL_SECRET`, `LINE_CHANNEL_ACCESS_TOKEN`,
  `LINE_OA_BASIC_ID` (optional), `CRON_WORKER_TOKEN`.
- Schedule `process-line-inbox` and `process-pending-actions` every 1
  minute (e.g. `pg_cron` → `net.http_post` with the worker token header).
- Live-API verification (signature check, real LINE account round trip)
  cannot happen in this dev environment — do it against a LINE Developers
  **sandbox** channel first.

**Google Calendar (WP7):**
- Google Cloud Console: enable Calendar API, create a **separate** OAuth
  client from Supabase Auth's Google Sign-In client, with redirect URI
  pointed at the deployed `google-calendar-oauth-callback` function and
  exactly the `calendar.events` + `calendar.calendarlist.readonly` scopes.
- Consent screen must eventually move out of Testing (7-day refresh-token
  expiry otherwise) — a human needs to click "Publish app" or add test
  users.
- Supabase secrets: `GOOGLE_CALENDAR_CLIENT_ID`,
  `GOOGLE_CALENDAR_CLIENT_SECRET`, `GOOGLE_CALENDAR_REDIRECT_URI`,
  `GOOGLE_TOKEN_ENCRYPTION_KEY` (base64 32-byte AES-256 key, e.g. `openssl
  rand -base64 32` — losing/rotating this invalidates every stored
  connection), `GOOGLE_CALENDAR_WEBHOOK_URL`, `APP_BASE_URL`.
- Schedule `enqueue-periodic-google-sync` (30 min), `process-google-sync`
  (1 min), `renew-google-watch` (30-60 min) as cron workers.
- Live-API verification cannot happen here — do it against a scratch
  calendar + Testing-mode consent screen first.

**Gemini (WP5, referenced, not detailed in MANUAL_SETUP_REQUIRED.md yet):**
`GEMINI_API_KEY`, `GEMINI_MODEL_PARSE`, `GEMINI_MODEL_REWRITE` — none of
these exist in this dev environment either; same never-fabricate rule
applies. Worth adding an explicit section to `MANUAL_SETUP_REQUIRED.md` for
this during WP9 or WP12, since it hasn't been written yet.

**Backup/recovery (WP10):** age public key must live in CI secrets only;
the corresponding private key is owner-held and never scriptable from CI —
see `docs/BACKUP_RESTORE_RUNBOOK.md` for the full procedure (already
written).

---

*This file should be updated (not deleted) at the end of each future
work session until WP12 is complete, so it always reflects the true current
state. Once WP12's final report is delivered, it can be superseded by that
report or removed at the user's discretion.*

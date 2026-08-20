# CONTINUATION — Family Ops v6 implementation

Regenerated after a SECOND independent design review (reviewer "Sol",
re-review) found 2 further P1s and 1 P2 against the fixed HEAD that had
already closed the first round's 4 P1s + 2 P2s. All are now closed too.
This file describes the actual, current state of the repository as of the
HEAD declared below — not a historical log. Read it fully before doing
anything else.

`scripts/check_continuation_head.mjs` mechanically verifies this file's
declared HEAD hasn't gone stale relative to the most recent (non-meta)
code-touching commit — run it before packaging any future review ZIP
(Sol's original P2-1 mandatory-gate item #10). Note: the checker treats
commits that touch only `CONTINUATION.md` and/or itself as "meta" and
skips them when computing the actual head — see the script's own header
comment for why a plain pathspec exclusion doesn't work here.

## 1. Current HEAD commit hash

```
b1af2bb39fe03beb43120db83dc150b87889089e
```
(branch `claude/family-ops-v6-implementation-6x4mft`, pushed to `origin`,
PR #1 on `syoudai0514/family-ops`. This regeneration's own commit touches
only this file, so `scripts/check_continuation_head.mjs` correctly treats
it as "meta" and resolves the actual head to this same `b1af2bb` — see
that script's header comment for why.)

**CI status for this commit**: all 4 required jobs are confirmed green —
`web`, `db`, `edge-functions`, `supabase-integration` (checked directly
against PR #1's check runs for commit `b1af2bb`).

## 2. Completed work: all of WP2–WP12, plus BOTH of Sol's review-fix cycles

Every work package the user requested (WP2 through WP12) is implemented,
tested, and committed. All 52 functions in the vendored v6 design's
normative matrix are deployed (56 total with 4 documented, ADR-recorded
gap-fill functions). No v7 redesign exists anywhere in this repo;
`docs/design/v6/` was never edited.

High-level inventory at this HEAD:
- **50** migrations (`supabase/migrations/*.sql`) — unchanged since the
  first review-fix cycle; this second cycle needed zero migrations (see
  §3's decision 1 rationale in `docs/adr/0010`).
- **56** Edge Functions (`supabase/functions/*/`, excluding `_shared/`)
- **27** SQL test files (`tests/sql/*.sql`), all passing together with 5
  true-parallel concurrency races (`scripts/run_concurrency_tests.sh`)
- **2** new pure-logic TypeScript modules with their own `deno test` unit
  tests (`process-line-inbox/routineItemFlow.ts`,
  `send-notifications/routineQuickReply.ts`) — 15 new test cases, on top
  of the pre-existing `_shared/gemini.test.ts` (44) and `_shared/auth.test.ts` (8)
- **10** ADRs (`docs/adr/0001`–`0010`) documenting every genuine v6-design
  gap filled, each with the minimal reasoned decision taken

### Feature areas (all implemented)
Household setup/invite, task/request/shopping/handover/notification
mutations, the full manual PWA, the recurrence engine (role-based
reassignment, mid-cycle changes), Gemini AI-draft propose/confirm, LINE
foundation (account linking, inbox worker, action queue, real push
delivery, Reply-API-first delivery, full quick-reply routine automation —
全部完了 / 項目ごとに入力 item-by-item flow / confirmed 今回は不要 / PWAで開く),
Google Calendar (OAuth/watch/sync-queue/projection/writes, merged into the
LINE digest with conflict-warning detection), scheduled LINE routine
dispatch (dispatch-routine-automation, routine sessions, PWA check-in),
backup/recovery, realtime partner sync + planned-vs-actual history,
production-readiness runbooks, and the three previously-missing normative
cron workers (`materialize-recurring`, `sync-jp-holidays`,
`cleanup-expired-private-data`).

### Commit history (chronological, this branch)

| Commit | Summary |
|---|---|
| `a165860` … `2b65d57` | WP1 review-fix round (pre-dates this file's first regeneration; see `git log` for the full WP0/WP1 history) |
| `f9e135c` | WP2 prep (P2): recurrence overlap concurrency test, LINE redelivery runbook |
| `e7a7a9a` | **WP2**: full manual PWA backend (16 RPCs, 24 Edge Functions) + entire `apps/web/` frontend |
| `153c4af` | **WP10**: backup/recovery — daily encrypted dump, R2, restore drill |
| `a48fcc1` | **WP3**: recurrence engine — `change-recurrence`, `reassign-task-once` |
| `0858582` | **WP5**: Gemini AI-draft propose/confirm flow |
| `b236162` | **WP6**: LINE foundation — account linking, inbox worker, action queue |
| `f1f5bc9` | **WP7**: Google Calendar — OAuth/watch/sync-queue/projection/writes |
| `fb8ec3b` | CI fix: `cryptoHelper.ts` Deno/TypeScript version drift |
| `7b07014` | **WP9**: real LINE push delivery — notification_outbox bridge + send-notifications |
| `1a8f836` | **WP8**: scheduled LINE routines — dispatcher, sessions, PWA check-in |
| `1b61e79` | **WP4**: realtime partner sync + planned-vs-actual history |
| `1fdcaf9` | Gap-close: `materialize-recurring`/`sync-jp-holidays`/`cleanup-expired-private-data` (all 52/52 normative functions now deployed) |
| `440dc1a` | **WP11**: production readiness runbook (12 items) |
| `2e49be2` | Self-review: bring `docs/adr/README.md` index up to date |
| — | *(WP12 self-review round completed here; then Sol's FIRST review found 4 P1s + 2 P2s — commits below are that fix cycle)* |
| `184e92f` | **Sol #1 P1-1/P1-2**: routine digest Google Calendar merge + conflict-warning detection |
| `2c24cac` | **Sol #1 P1-3/P1-4**: LINE quick-reply buttons (全部完了/今回は不要 only) + Reply-API-first delivery |
| `419023a` | CI fix: `tests/sql/25` assumed a nondeterministic bundled-item array order |
| `2644b32` | **Sol #1 P2-2**: provider-wire live-test evidence log template |
| `fd42e36` | CI fix: `change-recurrence` must map Postgres `deadlock_detected` to `RECURRENCE_OVERLAP` the same way `exclusion_violation` already is |
| `8d5b36f` | **Sol #1 P2-1**: first CONTINUATION.md regeneration + release-check script (this script itself had a self-reference bug — see next row) |
| `51bdab8` | Fix: `check_continuation_head.mjs`'s own self-reference bug (a plain pathspec exclusion broke on its own introducing commit) |
| — | *(all 10 of Sol's first-round mandatory-gate items confirmed at `51bdab8`, ZIP delivered; then Sol's SECOND review — a re-review of that exact ZIP — found 2 further P1s + 1 P2, since the first LINE quick-reply fix had deliberately left 項目ごとに入力 PWA-only and 今回は不要 unconfirmed — commit below is that fix cycle)* |
| `b1af2bb` | **Sol #2 (re-review) P1-1/P1-2/P2-1**: LINE-native 項目ごとに入力 item-by-item flow, mandatory confirmation before 今回は不要's mass-skip, and cleanup of `MANUAL_SETUP_REQUIRED.md`'s stale WP6 section (see `docs/adr/0010`) |

## 3. Incomplete work

**None at the WP level.** WP2 through WP12 are all complete, and BOTH of
Sol's review-fix cycles (4+2 the first round, 2+1 the second) are closed
out.

What remains is exactly what `MANUAL_SETUP_REQUIRED.md` and
`docs/PRODUCTION_READINESS_RUNBOOK.md` §13 already say cannot be done from
this repo alone:

- **Live provider verification** — LINE sandbox, Google Calendar scratch
  calendar, and physical iPhone testing have not been performed (no
  credentials exist in this dev environment by design). See
  `docs/PRODUCTION_READINESS_RUNBOOK.md` §13's checklist and evidence log
  — currently empty, all items outstanding. This is expected, not a defect;
  a human must complete it before production launch.
- **Manual external-service setup** — every item in `MANUAL_SETUP_REQUIRED.md`
  (LINE Developers console, Google Cloud Console OAuth client, Supabase
  secrets, cron scheduling for all worker functions) requires a human with
  access to those consoles. This file was itself cleaned up in `b1af2bb`
  (Sol #2 P2-1) — it no longer contradicts itself about whether the LINE
  push-send loop exists.
- Small, precisely-scoped, non-blocking design decisions recorded (not
  silently skipped) in ADRs: the two optional dedicated error codes
  `ROUTINE_SESSION_SUPERSEDED`/`ROUTINE_SESSION_NOT_OPEN` in place of the
  adequate-but-generic `TASK_TERMINAL`/`CROSS_HOUSEHOLD_RESOURCE` reuse
  (`docs/adr/0007`); quick-reply buttons not surviving the (expected-rare)
  LINE push-fallback path for the item-by-item flow, mitigated by always
  folding the PWA link into the message text itself (`docs/adr/0010`
  decision 8); and §8's forward-looking "future mandatory/non-skippable
  task" carve-out, which has no corresponding concept anywhere in this
  schema today (`docs/adr/0010` decision 9).

## 4. Concrete next steps (if resuming further work)

All 4 CI jobs are confirmed green for `b1af2bb` (see §1) — nothing left to
check there. If resuming further work:

1. If a human performs the live-provider testing in
   `docs/PRODUCTION_READINESS_RUNBOOK.md` §13 and finds issues, fix them
   as new, normally-scoped commits (same conventions as everything above:
   never edit `docs/design/v6/`, amend existing `server_tx_*` functions via
   a new migration rather than editing an already-committed one in place,
   run the full `tests/sql/00-26` + concurrency suite and the full
   `deno test --allow-env` suite before committing).
2. Before packaging any future review ZIP: run
   `node scripts/check_continuation_head.mjs` — it fails loudly if this
   file has gone stale relative to a newer non-meta commit, so regenerate
   it (like this pass did) before shipping if it fails.
3. Rebuild the ZIP with `git archive --format=zip -o <name>.zip HEAD` (no
   `node_modules`/`.git`/build output/secrets — `git archive` only
   includes tracked files, which already excludes all of those).

## 5. Uncommitted / unpushed changes

**None** once this file's own commit lands and is pushed. `HEAD` after
that commit matches `origin/claude/family-ops-v6-implementation-6x4mft`.

## 6. Tests executed and results (as of `b1af2bb`)

- **Local SQL suite** (`tests/sql/00_local_auth_shim.sql` through
  `26_line_item_by_item_and_skip_confirm.sql`, 27 files) + **all 5
  true-parallel concurrency races** (MI-HH03, M-01, LQA01/LQA02, MI-RR01,
  MI-RR02): **all PASS**, verified across 3 consecutive fresh-database runs
  locally.
- **`deno test --allow-env`** across `supabase/functions/`: **67/67 PASS**
  (8 `_shared/auth.test.ts` + 44 `_shared/gemini.test.ts` + 9 new
  `process-line-inbox/routineItemFlow.test.ts` + 6 new
  `send-notifications/routineQuickReply.test.ts`).
- **`deno lint`** across the full `supabase/functions/` tree: clean.
- **`deno check`** on every touched Edge Function entry point
  (`process-line-inbox/index.ts`, `send-notifications/index.ts`), against
  this environment's Deno pinned to 2.9.5 / TypeScript 6.0.3 (matching CI
  exactly): clean.
- **`node scripts/check-edge-auth-matrix.mjs`**: passes — all 52 normative
  functions deployed, 56 total with 4 documented gap-fill functions, each
  with the correct `verify_jwt` classification (unchanged by this cycle —
  no new Edge Function endpoints were added, only new postback branches
  inside two already-deployed functions).
- **Frontend** (`apps/web`): unaffected by this review-fix cycle (no
  `apps/web` files changed) — last verified green as of `1b61e79`.
- **GitHub Actions CI**: all 4 jobs (`web`, `db`, `edge-functions`,
  `supabase-integration`) confirmed green for `b1af2bb`.

## 7. Manual setup required (human action)

Unchanged in substance from before this review-fix cycle — full detail in
`MANUAL_SETUP_REQUIRED.md`, which `b1af2bb` corrected to remove stale
"not built" language (it now accurately reflects that the LINE push-send
loop, the LINE-native item-by-item flow, and the routine-session postback
wiring are all built). Summary: LINE Developers console (webhook URL,
`LINE_CHANNEL_SECRET`/`LINE_CHANNEL_ACCESS_TOKEN`/`LINE_OA_BASIC_ID`,
worker scheduling), Google Cloud Console (separate OAuth client from
Google Sign-In, scopes, consent-screen publishing status,
`GOOGLE_CALENDAR_CLIENT_ID`/`SECRET`/`REDIRECT_URI`,
`GOOGLE_TOKEN_ENCRYPTION_KEY`, `GOOGLE_CALENDAR_WEBHOOK_URL`,
`APP_BASE_URL`, worker scheduling), `CRON_WORKER_TOKEN` for all 10 worker
functions (rotation procedure documented in
`docs/PRODUCTION_READINESS_RUNBOOK.md` §6), `GEMINI_API_KEY` and related
env vars, and the age keypair for backups
(`docs/BACKUP_RESTORE_RUNBOOK.md`). None of these secrets exist in this
dev environment and none were fabricated anywhere in this repo.

---

*Keep this file updated (regenerate fully, don't hand-patch) whenever
significant new work lands, and always before packaging a review ZIP —
`scripts/check_continuation_head.mjs` enforces the second part
mechanically.*

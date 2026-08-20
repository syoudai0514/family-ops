# CONTINUATION — Family Ops v6 implementation

Regenerated from scratch after an independent design review (reviewer
"Sol") found 4 P1s and 2 P2s against the WP2–WP12 implementation, and all
were fixed. This file describes the actual, current state of the
repository as of the HEAD declared below — not a historical log. Read it
fully before doing anything else.

`scripts/check_continuation_head.mjs` mechanically verifies this file's
declared HEAD hasn't gone stale relative to the most recent code-touching
commit — run it before packaging any future review ZIP (Sol's P2-1
mandatory-gate item #10 for exactly this reason: this file went stale once
already mid-session).

## 1. Current HEAD commit hash

```
fd42e36b59134fd4619e37eb470e62fe506cfc85
```
(branch `claude/family-ops-v6-implementation-6x4mft`, pushed to `origin`,
PR #1 on `syoudai0514/family-ops`.)

**CI status for this commit**: all 4 required jobs are confirmed green —
`web`, `db`, `edge-functions`, `supabase-integration` (checked directly
against PR #1's check runs). This satisfies Sol's mandatory-gate item #8
("GitHub Actions is green on the exact fixed HEAD"). (This repo hit two
real, now-fixed CI failures earlier in this same review-fix cycle — a test
assuming a nondeterministic item-bundling order, and a Postgres deadlock
path that wasn't mapped to the same friendly error an exclusion violation
already was — both are fixed in commits on top of this same branch; see
the table below.)

## 2. Completed work: all of WP2–WP12, plus Sol's full review-fix cycle

Every work package the user requested (WP2 through WP12) is implemented,
tested, and committed. All 52 functions in the vendored v6 design's
normative matrix are deployed (56 total with 4 documented, ADR-recorded
gap-fill functions). No v7 redesign exists anywhere in this repo;
`docs/design/v6/` was never edited.

High-level inventory at this HEAD:
- **50** migrations (`supabase/migrations/*.sql`)
- **56** Edge Functions (`supabase/functions/*/`, excluding `_shared/`)
- **26** SQL test files (`tests/sql/*.sql`), all passing together with 5
  true-parallel concurrency races (`scripts/run_concurrency_tests.sh`)
- **9** ADRs (`docs/adr/0001`–`0009`) documenting every genuine v6-design
  gap filled, each with the minimal reasoned decision taken

### Feature areas (all implemented)
Household setup/invite, task/request/shopping/handover/notification
mutations, the full manual PWA, the recurrence engine (role-based
reassignment, mid-cycle changes), Gemini AI-draft propose/confirm, LINE
foundation (account linking, inbox worker, action queue, real push
delivery, Reply-API-first delivery, quick-reply routine buttons), Google
Calendar (OAuth/watch/sync-queue/projection/writes, now also merged into
the LINE digest with conflict-warning detection), scheduled LINE routine
dispatch (dispatch-routine-automation, routine sessions, PWA check-in),
backup/recovery, realtime partner sync + planned-vs-actual history,
production-readiness runbooks, and the three previously-missing normative
cron workers (`materialize-recurring`, `sync-jp-holidays`,
`cleanup-expired-private-data`).

### Commit history (chronological, this branch)

| Commit | Summary |
|---|---|
| `a165860` … `2b65d57` | WP1 review-fix round (pre-dates this file's regeneration; see `git log` for the full WP0/WP1 history) |
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
| — | *(WP12 self-review round completed here; then an independent review by "Sol" found 4 P1s + 2 P2s — the commits below are that review's fix cycle)* |
| `184e92f` | **Sol P1-1/P1-2**: routine digest Google Calendar merge + conflict-warning detection |
| `2c24cac` | **Sol P1-3/P1-4**: LINE quick-reply buttons + Reply-API-first delivery |
| `419023a` | CI fix: `tests/sql/25` assumed a nondeterministic bundled-item array order |
| `2644b32` | **Sol P2-2**: provider-wire live-test evidence log template |
| `fd42e36` | CI fix: `change-recurrence` must map Postgres `deadlock_detected` to `RECURRENCE_OVERLAP` the same way `exclusion_violation` already is |

## 3. Incomplete work

**None at the WP level.** WP2 through WP12 are all complete, and Sol's
full P1/P2 review-fix list is closed out.

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
  access to those consoles.
- Two small, precisely-scoped, non-blocking design decisions are recorded
  (not silently skipped) in ADRs: item-level (not just session-level) LINE
  quick-reply buttons for routine checklists (`docs/adr/0009`, since the
  notification payload bundles one item per schedule_kind, not per task —
  fixing this touches the WP8 dispatch migration and was out of scope for
  the P1-3 fix that landed), and the two optional dedicated error codes
  `ROUTINE_SESSION_SUPERSEDED`/`ROUTINE_SESSION_NOT_OPEN` in place of the
  adequate-but-generic `TASK_TERMINAL`/`CROSS_HOUSEHOLD_RESOURCE` reuse
  (`docs/adr/0007`).

## 4. Concrete next steps (if resuming further work)

All 4 CI jobs are confirmed green for `fd42e36` (see §1) — nothing left to
check there. If resuming further work:

1. If a human performs the live-provider testing in
   `docs/PRODUCTION_READINESS_RUNBOOK.md` §13 and finds issues, fix them
   as new, normally-scoped commits (same conventions as everything above:
   never edit `docs/design/v6/`, amend existing `server_tx_*` functions via
   a new migration rather than editing an already-committed one in place,
   run the full `tests/sql/00-25` + concurrency suite before committing).
2. Before packaging any future review ZIP: run
   `node scripts/check_continuation_head.mjs` — it fails loudly if this
   file has gone stale relative to a newer code-touching commit, so
   regenerate it (like this pass did) before shipping if it fails.
3. Rebuild the ZIP with `git archive --format=zip -o <name>.zip HEAD` (no
   `node_modules`/`.git`/build output/secrets — `git archive` only
   includes tracked files, which already excludes all of those).

## 5. Uncommitted / unpushed changes

**None.** `git status --short` is empty as of this file's own commit.
`HEAD` (`fd42e36`) matches
`origin/claude/family-ops-v6-implementation-6x4mft`.

## 6. Tests executed and results (as of `fd42e36`)

- **Local SQL suite** (`tests/sql/00_local_auth_shim.sql` through
  `25_line_reply_and_quick_actions.sql`, 26 files) + **all 5 true-parallel
  concurrency races** (MI-HH03, M-01, LQA01/LQA02, MI-RR01, MI-RR02): **all
  PASS**, verified across 5 consecutive fresh-database runs locally (the
  deadlock-mapping fix in `fd42e36` addresses a genuinely timing-dependent
  failure mode, so single-run confidence wasn't sufficient).
- **`deno lint`** across the full `supabase/functions/` tree (69 files):
  clean.
- **`deno check`** on every deployed Edge Function, against this
  environment's Deno pinned to 2.9.5 / TypeScript 6.0.3 (matching CI
  exactly — this pin exists specifically because an earlier commit in this
  session's history failed CI on a Deno-version-specific typed-array
  typing issue that an older local Deno didn't catch): clean.
- **`node scripts/check-edge-auth-matrix.mjs`**: passes — all 52 normative
  functions deployed, 56 total with 4 documented gap-fill functions, each
  with the correct `verify_jwt` classification.
- **Frontend** (`apps/web`): typecheck clean, `oxlint` clean aside from
  pre-existing P2/P3-level warning patterns (`set-state-in-effect`,
  `only-export-components` — not blocking), `npm test -- --run` passing
  (23/23 as of the last frontend-touching commit, `1b61e79`; no frontend
  files changed since), production build succeeds.
- **`deno test` on `_shared/gemini.test.ts`**: 44/44 invariant-check unit
  tests passing (no live Gemini calls).
- **GitHub Actions CI**: see section 1 above for this exact commit's
  status; every earlier commit back through `440dc1a` was confirmed
  all-4-jobs-green before the next commit landed (with two exceptions
  — `419023a` and `fd42e36` — which exist specifically *because* the
  commit immediately before each of them briefly broke CI; both were
  root-caused and fixed the same review cycle, not left red).

## 7. Manual setup required (human action)

Unchanged from before this review-fix cycle — full detail in
`MANUAL_SETUP_REQUIRED.md`. Summary: LINE Developers console (webhook URL,
`LINE_CHANNEL_SECRET`/`LINE_CHANNEL_ACCESS_TOKEN`/`LINE_OA_BASIC_ID`,
worker scheduling), Google Cloud Console (separate OAuth client from
Google Sign-In, scopes, consent-screen publishing status,
`GOOGLE_CALENDAR_CLIENT_ID`/`SECRET`/`REDIRECT_URI`,
`GOOGLE_TOKEN_ENCRYPTION_KEY`, `GOOGLE_CALENDAR_WEBHOOK_URL`,
`APP_BASE_URL`, worker scheduling), `CRON_WORKER_TOKEN` for all 10 worker
functions (rotation procedure now documented in
`docs/PRODUCTION_READINESS_RUNBOOK.md` §6), `GEMINI_API_KEY` and related
env vars, and the age keypair for backups
(`docs/BACKUP_RESTORE_RUNBOOK.md`). None of these secrets exist in this
dev environment and none were fabricated anywhere in this repo.

---

*Keep this file updated (regenerate fully, don't hand-patch) whenever
significant new work lands, and always before packaging a review ZIP —
`scripts/check_continuation_head.mjs` enforces the second part
mechanically.*

# Production Readiness Runbook (WP11)

Operational procedures for running Family Ops v6 in production. This
complements, rather than repeats, two existing docs:
- `docs/RUNBOOK.md` — general operational notes (LINE webhook redelivery,
  never hard-deleting `auth.users` rows).
- `docs/BACKUP_RESTORE_RUNBOOK.md` — backup/restore/drill procedures (item
  12 below is a pointer into that doc, not a duplicate).

Every item here maps to one bullet in `docs/design/v6/10_WORK_PACKAGES.md`'s
WP11 entry.

## 1. iPhone PWA end-to-end check

A human with an iPhone must verify, before relying on this in daily use:
1. Open the deployed PWA URL in Safari, tap Share → "Add to Home Screen."
   Confirm the app icon/name (from `apps/web/public/manifest.webmanifest`)
   and that it launches full-screen (no Safari chrome) from the home
   screen icon.
2. With the app installed and a household set up, put the phone in
   Airplane Mode and reopen the app from the home screen icon. Confirm the
   already-cached `GET /rest/v1/*` reads still render (Today/Requests/
   Shopping/etc. show their last-fetched data) per the NetworkFirst PWA
   caching in `apps/web/vite.config.ts` — mutations will correctly fail
   (no network), which is expected; only reads are meant to work offline.
3. Turn Airplane Mode back off and confirm the app recovers (a manual
   pull-to-refresh or navigating between tabs re-fetches live data — there
   is no automatic "back online" toast, by design; don't file that as a
   bug).
4. Confirm `/checkin/:sessionId` opens correctly when tapped as a LINE
   message's auto-linkified URL (Safari should open it in the installed
   PWA if "Open in App" behavior is configured via the manifest'
   `start_url`/`scope`, otherwise it opens in a normal Safari tab — either
   is acceptable, but verify neither redirects to a broken URL or a
   sign-in loop).
5. iOS Safari does **not** support the Web Push API the way Chrome/
   Android does — this app doesn't rely on it (LINE is the actual push
   channel; the PWA is pull/in-app-only for notifications). Nothing to fix
   here — just don't expect a native iOS push notification from the PWA
   itself.

## 2. Supabase Free tier pause/recovery

Supabase's Free tier auto-pauses a project after 7 days with no API
requests. If the project is paused:
1. Supabase Dashboard → Project → click "Restore project." This can take a
   few minutes.
2. Once restored, verify migrations are intact:
   `supabase db diff --linked` (via the pinned CLI, `2.115.0`) should show
   no diff against `supabase/migrations/`. If it does, the project was
   restored to an older snapshot than expected — investigate before
   resuming traffic.
3. Verify Edge Functions are still deployed:
   `supabase functions list` should show all 56 functions (52 normative +
   4 documented gap-fill — see `scripts/check-edge-auth-matrix.mjs`'s
   output for the exact current list). Supabase does **not** typically
   lose deployed functions on a pause/restore cycle, but confirm rather
   than assume.
4. Verify all cron schedules (pg_cron or external scheduler — see item 6
   and each function's own `MANUAL_SETUP_REQUIRED.md` entry) are still
   registered; a pause/restore has in the past been observed to drop
   `pg_cron` job rows on some Supabase plans. Re-run whatever setup script
   or `cron.schedule(...)` calls originally created them if `select * from
   cron.job;` comes back empty or incomplete.
5. **Before this matters in practice**: watch invocation volume against
   the Free tier's 500k Edge Function invocations/month cap
   (`docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md` #20 — warn at 350k,
   investigate at 400k). Ten worker functions polling every 1-60 minutes
   plus real user traffic can approach this for a multi-household
   deployment; if it does, that's the signal to move to a paid plan before
   a pause/rate-limit event happens, not after.

## 3. Calendar OAuth in production

See `MANUAL_SETUP_REQUIRED.md`'s "Google Calendar (WP7)" section for the
one-time setup (separate OAuth client, scopes, redirect URI, secrets).
Ongoing production concerns:
1. **Publishing status gate**: while the OAuth consent screen is in
   Testing mode, every connected household's refresh token silently
   expires after 7 days, surfacing as `CALENDAR_REAUTH_REQUIRED` the next
   time `process-google-sync`/`renew-google-watch`/a calendar write runs
   (`server_tx_mark_google_reauth_required` already flips the connection
   rather than retrying forever — see `docs/adr/0005`). Before onboarding
   any household beyond the developer's own test account, click "Publish
   app" in Google Cloud Console's OAuth consent screen settings (or keep
   adding every household's Google account as a Test User, which doesn't
   scale past a handful of households).
2. **Google's own app verification**: publishing an app requesting
   `calendar.events`/`calendar.calendarlist.readonly` scopes to
   "In production" may trigger Google's OAuth verification review
   (required once the app is used by enough distinct Google accounts,
   independent of Family Ops' own household count). Budget lead time for
   this — it is a Google-side process this repo cannot automate or
   shortcut.
3. Monitor for `CALENDAR_REAUTH_REQUIRED` connections in
   `public.calendar_connections` (or wherever the connection status is
   surfaced) periodically — a household stuck in this state gets no
   calendar sync until a human in that household re-authorizes via
   `google-calendar-oauth-start`.

## 4. LINE quota / failure handling

The LINE Messaging API free tier caps monthly pushes; `private.line_quota_state`
+ `server_tx_reserve_line_quota` (WP1) enforce an internal hard cap of 200
with a configurable soft-budget reminder threshold, refreshed against the
provider's own quota/consumption endpoints by `send-notifications` (WP9)
at least every 15 minutes while stale.
1. **Approaching the cap**: `send-notifications`' run summary
   (`quota_fallback` count in its JSON response, logged per invocation)
   rising indicates households are hitting `quota_fallback` — those
   notifications degrade to in-app-only (the `user_notifications` row
   always exists regardless of LINE delivery, per
   `docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md` #22) rather than being
   lost. This is expected, graceful behavior, not an incident by itself —
   but sustained high `quota_fallback` volume means it's time to either
   upgrade the LINE plan or investigate an unexpectedly chatty
   notification source (check `notification_outbox.type` distribution).
2. **Provider-side outage/repeated 5xx**: `sendOne`'s `ambiguous` outcome
   (delivery-unknown, retried with the same `X-Line-Retry-Key` so a
   provider-side "actually it did send" is never double-delivered) handles
   transient failures automatically — no manual action needed unless
   `notification_outbox` rows are piling up in `delivery_unknown` for an
   extended period (check LINE's own status page).
3. **`LINE_CHANNEL_ACCESS_TOKEN` expired/revoked**: every push starts
   failing with 401/403, classified as `definitive` (never retried) by
   `sendOne`. Rotate the token in the LINE Developers console and update
   the Supabase secret (`supabase secrets set LINE_CHANNEL_ACCESS_TOKEN=...`).

## 5. Gemini quota / fallback

`propose-ai-draft` (WP5) raises `AI_UNAVAILABLE` (503) on any Gemini API
failure — including quota exhaustion — never blocking the underlying
feature: the user can always fall back to typing the request/handover text
directly (skipping the AI-draft propose/confirm flow entirely and calling
`send-request`/`create-handover` with their own final text). No queue, no
retry — this is a synchronous user-facing call, so the "recovery" is simply
"the user tries again later or types it manually," which the PWA should
already surface as the `AI_UNAVAILABLE` error message
(`_shared/errors.ts`'s `describeCode` Japanese string). If `AI_UNAVAILABLE`
becomes frequent, check the Gemini API quota/billing dashboard for the
configured `GEMINI_API_KEY`'s project.

## 6. Cron worker token rotation

`CRON_WORKER_TOKEN` (`X-Family-Ops-Worker-Token`, constant-time-compared in
`_shared/auth.ts`'s `requireWorkerToken`) gates every `verify_jwt=false`
worker function — currently 10 of them:
`cleanup-expired-private-data`, `dispatch-routine-automation`,
`enqueue-periodic-google-sync`, `materialize-recurring`,
`process-google-sync`, `process-line-inbox`, `process-pending-actions`,
`renew-google-watch`, `send-notifications`, `sync-jp-holidays`.
(`line-webhook-receiver` and `google-calendar-webhook` are also
`verify_jwt=false` but authenticate differently — LINE signature and
watch-channel-row lookup respectively, not this token.)

To rotate:
1. Generate a new random value (e.g. `openssl rand -hex 32`).
2. `supabase secrets set CRON_WORKER_TOKEN=<new-value>`.
3. Update the header value on **every** scheduled invocation of the 10
   functions above (whatever scheduler is in use — `pg_cron` →
   `net.http_post` with a hardcoded header, or an external scheduler's
   stored config) to the same new value, in the same deploy/change window
   as step 2 — there is no dual-token grace period, so a scheduler still
   using the old token gets `EDGE_WORKER_UNAUTHORIZED` (401) starting
   immediately after step 2 lands.
4. Confirm the next scheduled run of each function succeeds (check
   Supabase's function invocation logs, or each function's own JSON
   response body if the scheduler surfaces it) before considering the
   rotation complete.

## 7. Queue dead-letter runbook

Every durable queue in this system follows the same lease/reclaim/
dead-letter shape (`status` reaches `'dead'`/`'delivery_unknown'` after
`max_attempts`, default 5, is exhausted):

| Queue table | Worker | Dead status | Inspect |
|---|---|---|---|
| `private.webhook_inbox` | `process-line-inbox` | `'dead'` | `select * from private.webhook_inbox where status = 'dead' order by received_at desc;` |
| `private.pending_actions` | `process-pending-actions` (execution phase only — the draft/confirm/cancel staging phase in `process-line-inbox` never sets `'dead'`) | `'dead'` (execution retries exhausted) or `'expired'` (never confirmed before its TTL) | `select * from private.pending_actions where status in ('dead', 'expired');` |
| `private.notification_outbox` | `send-notifications` | `'dead'`/`'delivery_unknown'` | `select * from private.notification_outbox where status in ('dead', 'delivery_unknown');` |
| `private.google_sync_jobs` | `process-google-sync` | `'dead'` | `select * from private.google_sync_jobs where status = 'dead';` |
| `private.google_write_operations` | `create-calendar-event`/`update-calendar-event` (via `server_tx_finalize_google_write`) | `'dead'` | `select * from private.google_write_operations where status = 'dead';` |

General procedure for any of the above:
1. Read `last_error` on the dead row(s) to understand why every attempt
   failed (malformed payload, a since-fixed bug, a provider outage that
   outlasted the retry window, a permanently-invalid recipient, etc.).
2. **If the root cause is fixed** (e.g. a code bug that's since been
   patched and deployed): reset the row back to its retryable state and
   clear `attempts` — e.g. for `webhook_inbox`:
   `update private.webhook_inbox set status = 'received', attempts = 0,
   next_attempt_at = now() where id = '<id>';`. The next worker run picks
   it up normally. Apply the equivalent for whichever table.
3. **If the root cause is NOT fixable** (permanently invalid data, a user
   who unlinked LINE mid-flight, etc.): leave the row dead — it's the
   audit trail. Do not delete it manually; `cleanup-expired-private-data`
   (item 10 below) already has the correct retention rule for each table
   and will remove it on schedule.
4. **Never bulk-reset without reading `last_error` first** — resetting a
   systemically-broken payload just burns another 5 attempts for nothing.

## 8. Google missed-webhook convergence

Google's push notifications (`google-calendar-webhook`) are a
best-effort optimization, not the source of truth — `process-google-sync`'s
periodic 30-minute trigger (`enqueue-periodic-google-sync`) is the actual
convergence guarantee per `docs/design/v6/07_GOOGLE_CALENDAR.md` WP7C. If a
webhook notification is dropped (network blip, Google-side issue, a watch
channel that expired without renewal — see item 9), the affected calendar
still catches up within at most 30 minutes via the periodic sync, with no
manual intervention needed.

To verify convergence is actually working (e.g. after a suspected missed
webhook): check `private.google_sync_state.last_success_at` for the
affected `calendar_connection_id` — it should never be older than ~35
minutes (30-minute cadence + normal processing latency) for a connection
that isn't `reauth_required`. If it is stale beyond that, `process-google-sync`
itself isn't running — check its own scheduling (item 6) and recent
invocation logs before assuming it's a Google-side problem.

## 9. Watch renewal

`renew-google-watch` should run every 30-60 minutes. It does three things
in one pass: creates the initial watch channel for a newly-connected
household that doesn't have one yet, renews any `active` channel
approaching Google's ~7-day-imposed expiry (with overlap, so there's never
a gap with no active channel), and marks channels that finished their
`retiring` grace period as `stopped`.

To verify: `select calendar_connection_id, status, expires_at from
private.google_watch_channels where status = 'active' order by expires_at;`
— the soonest `expires_at` across all active channels should never be less
than roughly `now() + (renewal cadence + safety margin)` away; if one is
closer than that, either `renew-google-watch` isn't running on schedule
(item 6) or its renewal-threshold logic needs a wider margin — investigate
before it actually expires and that household silently falls back to
30-minute periodic sync only (still correct per item 8, just less prompt).

## 10. Cleanup

`cleanup-expired-private-data` should run daily at 03:30 Asia/Tokyo (see
`MANUAL_SETUP_REQUIRED.md`'s "Recurrence / holiday sync / cleanup workers"
section for the exact cron time in UTC and the full table-by-table
retention rule list). To verify it's running: its JSON response (visible in
Supabase's function invocation logs) reports a per-table deletion count
every run — a `raw_inputs` count of exactly 0 on every single run for an
extended period is a soft signal worth checking (either genuinely no
expired rows, which is possible on a quiet system, or the worker isn't
actually running — cross-check against invocation logs directly rather
than inferring from the count alone).

## 11. Scheduled notification timezone / idempotency

Every scheduled worker in this system computes "today"/"now" in Asia/Tokyo
explicitly (`(now() at time zone 'Asia/Tokyo')::date`, or the equivalent
`Date.toLocaleDateString('en-CA', { timeZone: 'Asia/Tokyo' })` on the Deno
side) — never the database server's or the scheduler's own local timezone,
which may be UTC. `dispatch-routine-automation`'s scheduled slots
(07:00/08:30/16:00/20:30/20:00/22:00 Asia/Tokyo, per
`docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md`) are each idempotent per
`(household_id, schedule_kind, scheduled_local_date, recipient_user_id)`
via `private.scheduled_dispatch_receipts`' unique constraint — a cron
retry, a scheduler double-fire, or a worker restart mid-run can never
produce two notifications for the same slot. If a production incident ever
looks like "the same reminder was sent twice," check first whether it was
actually two *different* scheduled slots (e.g. a 07:00 daily-assignment
message and an unrelated 08:30 check-in reminder can look similar but are
distinct rows) before assuming the idempotency guard failed.

## 12. Backup freshness

Already fully documented — see `docs/BACKUP_RESTORE_RUNBOOK.md` in full,
and specifically its "Release / monthly restore drill" section for the
recurring checklist. `scripts/backup_freshness_check.sh` +
`.github/workflows/backup_freshness_alert.yml` (WP10) already alert if the
most recent encrypted backup in R2 is older than the configured threshold
— nothing further needed here beyond following that doc's restore-drill
cadence.

# Manual setup required

Steps a human must complete outside this repo before the corresponding
feature works against real providers. Nothing below was fabricated — every
secret is referenced by env var name only; none exist in this dev
environment.

## LINE (WP6 — LINE foundation)

1. **LINE Developers console**: create/select a Messaging API channel for
   the Family Ops LINE Official Account.
2. Set the webhook URL to the deployed `line-webhook-receiver` Edge
   Function's URL (`https://<project-ref>.supabase.co/functions/v1/line-webhook-receiver`)
   and enable "Use webhook".
3. Configure these as Supabase project secrets (`supabase secrets set`),
   never committed to the repo:
   - `LINE_CHANNEL_SECRET` — used by `line-webhook-receiver` /
     `_shared/auth.ts:verifyLineSignature` to verify `X-Line-Signature`.
   - `LINE_CHANNEL_ACCESS_TOKEN` — needed once a LINE-push send loop calls
     the Messaging API (not built in WP6; see "Known follow-ups" below).
   - `LINE_OA_BASIC_ID` (optional) — the OA's `@`-prefixed Basic ID. When
     set, `create-line-link-token`'s response includes a
     `line_add_friend_url` deep link
     (`https://line.me/R/oaMessage/{basic_id}/?{token}`) that opens LINE
     with the link token pre-filled as the outgoing message. Without it,
     the raw token is still returned and can be pasted manually into a
     chat with the OA.
   - `CRON_WORKER_TOKEN` — shared secret for `X-Family-Ops-Worker-Token`,
     required by every `verify_jwt=false` worker function including
     `process-line-inbox` and `process-pending-actions`. Generate a random
     value and configure the same value on whatever scheduler invokes these
     functions every minute (Supabase's own pg_cron -> `net.http_post`, or
     an external scheduler).
4. Schedule `process-line-inbox` and `process-pending-actions` to run every
   1 minute (docs/design/v6/06_LINE_INTEGRATION.md #3;
   09_API_AND_EDGE_FUNCTIONS.md #6) — e.g. via `pg_cron` calling
   `net.http_post` with the `X-Family-Ops-Worker-Token` header, matching
   whatever mechanism already schedules `send-notifications`.
5. Live-API verification of the signature check, the actual claim flow
   against a real LINE user, and the eventual push-send loop all require a
   real `LINE_CHANNEL_SECRET`/`LINE_CHANNEL_ACCESS_TOKEN` and a real LINE
   account — none of that exists in this dev environment, so WP6's tests
   cover the DB/queue mechanics exhaustively (tests/sql/19_line_foundation.sql)
   but cannot exercise an actual LINE webhook delivery end to end. Do this
   against a LINE Developers **sandbox** channel before pointing at
   production.

### Known follow-ups (not P0/P1, intentionally deferred — see final report)

- The LINE **push send loop** itself (outbox claim, quota-permit reservation,
  actual `POST` to the LINE Messaging API, retry-key/409/429 handling) is
  `send-notifications`'s job and was **not** built in WP6 — the WP1 stub
  (auth boundary only) is still what's deployed. Until it exists,
  `process-line-inbox` cannot deliver an outbound confirm/cancel quick-reply
  for a natural-language pending action; those actions currently stay in
  `draft` until a human opens the PWA (once a PWA "LINE inbox" view exists)
  or the token/action expires.
- Natural-language grammar in `process-line-inbox/parser.ts` covers only
  shopping-item-add and one-off task-add deterministically. Partner-request
  rewrite and recurrence/reassignment edits via LINE text are recognized as
  "not auto-parsed" (`needs_pwa_review`) rather than guessed at, by design.

## Google Calendar (WP7 — Google Calendar integration)

1. **Google Cloud Console**: create (or reuse) a project, enable the
   **Google Calendar API**, and create a **separate** OAuth 2.0 **Web
   application** client for Calendar access — do **not** reuse the client
   Supabase Auth's Google Sign-In already uses; `07_GOOGLE_CALENDAR.md` #2
   requires app login and Calendar OAuth to be fully separate credentials.
   - Authorized redirect URI: the deployed `google-calendar-oauth-callback`
     Edge Function's URL
     (`https://<project-ref>.supabase.co/functions/v1/google-calendar-oauth-callback`).
   - Scopes to request (exactly these two, no more):
     `https://www.googleapis.com/auth/calendar.events` and
     `https://www.googleapis.com/auth/calendar.calendarlist.readonly`.
2. **OAuth consent screen publishing status**: while the consent screen
   stays in **Testing**, Google expires Calendar-scope refresh tokens after
   7 days, and every affected household will start seeing `invalid_grant`
   from the token endpoint — `renew-google-watch` /
   `process-google-sync` / `create-calendar-event` /
   `update-calendar-event` already handle this by flipping the connection
   to `reauth_required` (`server_tx_mark_google_reauth_required`) rather
   than retrying forever, but a human still has to click "Publish app" (or
   add the household's Google account as a Test User) before real
   day-to-day use, per #2 "Publishing status gate".
3. Configure these as Supabase project secrets (`supabase secrets set`),
   never committed to the repo:
   - `GOOGLE_CALENDAR_CLIENT_ID` / `GOOGLE_CALENDAR_CLIENT_SECRET` — the
     Calendar-only OAuth client from step 1.
   - `GOOGLE_CALENDAR_REDIRECT_URI` — must exactly match the Authorized
     redirect URI configured in Cloud Console.
   - `GOOGLE_TOKEN_ENCRYPTION_KEY` — a base64-encoded 32-byte (256-bit) key
     for AES-256-GCM refresh-token-at-rest encryption
     (`_shared/cryptoHelper.ts`), e.g. generated with `openssl rand -base64
     32`. Losing/rotating this key invalidates every stored connection
     (every household needs to reconnect) — back it up like any other
     production secret, and see `docs/adr/0005-google-calendar-new-error-codes.md`
     if a key-rotation "encryption_version 2" path is ever added.
   - `GOOGLE_CALENDAR_WEBHOOK_URL` — the deployed `google-calendar-webhook`
     Edge Function's public URL, passed to Google's `events.watch` as the
     push notification target.
   - `APP_BASE_URL` — the PWA's own origin (e.g.
     `https://familyops.example.app`), used by `google-calendar-oauth-callback`
     to build the final 302 redirect back into the app (`return_to` is only
     ever an app-relative path; this is what it's resolved against).
   - `CRON_WORKER_TOKEN` — already required by WP6; reused as-is by
     `google-calendar-webhook` (verify_jwt=false, but authenticates via the
     watch-channel row, not this token), and by `renew-google-watch`,
     `enqueue-periodic-google-sync`, `process-google-sync` (all
     verify_jwt=false, `X-Family-Ops-Worker-Token`).
4. Schedule these as cron workers (same mechanism as WP6's
   `process-line-inbox`/`process-pending-actions` — `pg_cron` ->
   `net.http_post` with the `X-Family-Ops-Worker-Token` header, or an
   external scheduler):
   - `enqueue-periodic-google-sync` every 30 minutes
     (`07_GOOGLE_CALENDAR.md` WP7C "periodic 30m").
   - `process-google-sync` every 1 minute (drains whatever the queue has —
     webhook-triggered, periodic, or manual `ensure-calendar-fresh`
     enqueues; it is a no-op / instant 200 when the queue is empty).
   - `renew-google-watch` every 30-60 minutes (creates the very first watch
     channel for a newly-connected household, renews channels approaching
     their ~7-day Google-imposed expiry with overlap, and stops channels
     that finished retiring).
5. `supabase/config.toml`'s `[functions.*]` entries for all 10 Google
   Calendar functions (and WP6's 4 LINE functions) have already been added
   by the orchestrator in a follow-up consolidation commit — no action
   needed here.
6. Live-API verification (actual OAuth consent/token exchange, actual
   `events.list`/`insert`/`patch`/`watch` calls, an actual push notification
   round trip) all require the real secrets above and a real Google account
   — none of that exists in this dev environment. `tests/sql/20_google_calendar.sql`
   exhaustively covers everything reachable without a live call (queue
   state machine, lease/reclaim/coalesce, syncToken storage/410 recovery,
   tombstone semantics, projection + busy-attribution precedence,
   deterministic-id write idempotency); the Google API wire calls
   themselves (`supabase/functions/_shared/googleCalendar.ts`) are
   implemented in full but untested end-to-end. Do this against a scratch
   Google Calendar + a Testing-mode OAuth consent screen before pointing at
   a real family's calendar.

## LINE push delivery (WP9 — notification UX / fatigue audit)

`send-notifications` now implements the actual outbox drain that WP6's
stub deliberately left unbuilt: lease/reclaim/dead-letter over
`private.notification_outbox`, atomic quota-permit reservation (reusing
WP1's `server_tx_reserve_line_quota`/commit/release/mark_ambiguous RPCs),
the real `POST https://api.line.me/v2/bot/message/push` call with a fixed
`X-Line-Retry-Key`, 409-reconcile/429-classification/5xx-ambiguous handling,
and same-recipient bundling (`docs/adr/0006-notification-outbox-delivery-bridge-and-conflict-deferral.md`
covers the bridge/bundling design). None of this can be live-tested in this
dev environment — see below.

1. **`LINE_CHANNEL_ACCESS_TOKEN`** (already listed above by WP6 as "needed
   once a LINE-push send loop calls the Messaging API") is what
   `send-notifications` now actually reads at runtime, on every invocation
   that has outbox work to send or a stale (>15m) quota cache to refresh. No
   other new secret is required — quota-usage refresh calls
   `GET /v2/bot/message/quota` and `GET /v2/bot/message/quota/consumption`
   with the same bearer token.
2. **Schedule `send-notifications` every 1 minute**
   (`docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md` #6 "Worker-only; every
   minute"), the same mechanism already used for `process-line-inbox` /
   `process-pending-actions` (`pg_cron` → `net.http_post` with the
   `X-Family-Ops-Worker-Token` header, or an external scheduler). No new
   worker secret is needed — it reuses the existing `CRON_WORKER_TOKEN`.
3. **Live-API verification** (an actual push delivered to a real LINE
   account, an actual 429/409 response from the real Messaging API, a real
   monthly-quota exhaustion) requires a real `LINE_CHANNEL_ACCESS_TOKEN` and
   a real LINE account — neither exists in this dev environment, matching
   WP6/WP7's own documented limitation. `tests/sql/21_notification_delivery.sql`
   exhaustively covers everything reachable without a live call (bridge/
   bundling at insert time, claim/lease/reclaim/dead-letter, the
   quota-reservation integration with WP1's existing RPCs, the
   `definitive`/`quota_fallback`/`ambiguous`/`transient` outcome state
   machine, retry-key idempotency across retries, and both the
   `business_expires_at` and `provider_retry_expires_at` expiry sweeps); the
   provider fetch() calls themselves
   (`supabase/functions/send-notifications/index.ts`) are implemented in
   full but untested end-to-end. Do this against a LINE Developers
   **sandbox** channel before pointing at production.
4. **Calendar change/conflict messages** (`docs/design/v6/10_WORK_PACKAGES.md`
   WP9) were deliberately **not** built as a standalone notification type in
   this work package — see `docs/adr/0006-notification-outbox-delivery-bridge-and-conflict-deferral.md`
   "Decision" #3 for why (the design only specifies this content as part of
   WP8's not-yet-built daily-assignment dispatcher message, with no
   independent trigger condition or copy of its own).

## Scheduled LINE household routines (WP8 — routine automation)

1. **Schedule `dispatch-routine-automation` every 1 minute**
   (`docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md` #13 "Scheduler worker ...
   every 1 minute"), the exact same mechanism already used for
   `process-line-inbox` / `process-pending-actions` / `send-notifications`
   (`pg_cron` → `net.http_post` with the `X-Family-Ops-Worker-Token` header,
   or an external scheduler). No new secret is required — it reuses the
   existing `CRON_WORKER_TOKEN`.
2. No new provider secret is needed for the dispatcher itself — it only ever
   inserts into `private.notification_outbox`; the actual LINE push is
   `send-notifications`' job (already covered above) and reuses the same
   `LINE_CHANNEL_ACCESS_TOKEN`.
3. **`APP_BASE_URL`** (referenced by `docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md`
   #8 for the `{APP_BASE_URL}/checkin/{session_id}` deep link) should already
   be configured from an earlier WP for other PWA deep links; no WP8-specific
   value is needed beyond ensuring the `/checkin/:sessionId` route (see final
   report) is deployed at that same base URL.
4. **Known follow-up, not P0/P1 but load-bearing for the LINE-side
   interaction loop** — see `docs/adr/0007-wp8-routine-session-scope-decisions.md`
   decisions 1 and 5: `process-line-inbox`'s `handlePostback` has no branch
   yet for routine-session postback actions (the RPC layer,
   `server_tx_routine_session_item_action` / `server_tx_complete_routine_session`,
   is fully built and tested for `p_source='line'` calls — only the webhook
   -> RPC wiring is outstanding), and `send-notifications` sends plain-text
   LINE messages only, with no quick-reply/template button support to attach
   the `[全部完了] [項目ごとに入力] [今回は不要] [PWAで開く]` actions to. Until
   both land, the PWA deep link included as plain text in each routine
   message is the only actionable affordance from LINE itself.
5. **Live-API verification** of an actual scheduled push arriving in a real
   LINE chat at the correct Asia/Tokyo minute requires the same real
   `LINE_CHANNEL_ACCESS_TOKEN`/LINE account already noted above — not
   available in this dev environment. `tests/sql/22_routine_line_automation.sql`
   exhaustively covers the dispatcher's own logic (idempotency under
   simulated cron retry, 07:00 bundling, weekend/holiday suppression,
   reminder suppression + auto-close, reassignment session supersede +
   immediate change notification, the unassigned-pickup/zero-item edge
   cases, custom schedule times, same-day no-auto-resend, and the
   notification-preference-off "session persists, LINE suppressed" case) and
   the routine-session action RPCs (LINE-postback-shaped and PWA-shaped
   calls, idempotent replay, stale-tap safety, access control) end to end
   against a local Postgres instance.

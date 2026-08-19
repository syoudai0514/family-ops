# Source Snapshot — verified 2026-08-19

外部仕様は変わり得る。実装時/リリース前に公式docsを再確認する。

## Supabase

Verified 2026-08-19:
- Auth supports Google Sign-In for web.
- Hosted Supabase supports scheduled Edge Functions using Cron/pg_cron + pg_net.
- RLS/private schema rules remain mandatory design concerns.

Official:
- https://supabase.com/docs/guides/auth/social-login/auth-google
- https://supabase.com/docs/guides/functions/schedule-functions
- https://supabase.com/docs/guides/cron
- https://supabase.com/docs/guides/database/postgres/row-level-security
- https://supabase.com/docs/guides/platform/backups

Design consequence:
- App Auth fixed to Supabase Google Sign-In.
- Worker scheduling fixed to Supabase Cron.
- private schema not browser exposed.

## Google Calendar

Verified 2026-08-19:
- watch channels have channel ID/resource ID/token/expiration.
- channels expire and must be renewed with new unique channel IDs.
- `events.list` incremental sync uses `syncToken`.
- with `syncToken`, `timeMin`, `timeMax`, `updatedMin`, `q`, `orderBy` and certain other params cannot be used.
- after expired/invalid sync token Google may return HTTP 410 and client must perform full sync.

Official:
- https://developers.google.com/workspace/calendar/api/guides/push
- https://developers.google.com/workspace/calendar/api/v3/reference/events/watch
- https://developers.google.com/workspace/calendar/api/guides/sync
- https://developers.google.com/workspace/calendar/api/v3/reference/events/list

Design consequence:
- watch channels separated from sync state.
- canonical syncToken stream separated from rolling occurrence projection.
- full sync uses staging to preserve existing cache on partial failure.

## LINE Messaging API

Verified 2026-08-19:
- redelivered webhook keeps the same `webhookEventId`.
- push-message APIs support `X-Line-Retry-Key`.
- retry key should be sent on the first request and reused on retry to avoid duplicate provider execution.
- reply messages do not use this retry-key mechanism.

Official:
- https://developers.line.biz/en/docs/messaging-api/receiving-messages/
- https://developers.line.biz/en/docs/messaging-api/retrying-api-request/
- https://developers.line.biz/en/reference/messaging-api/

Design consequence:
- inbox dedupe by webhookEventId.
- durable outbound notifications use push with fixed provider retry key.

## Gemini

User decision:
- free Gemini remains in MVP.
- AI privacy topic is not a blocker for this review.
- basic secret/financial/exact-address/detailed-medical guard retained.

Official:
- https://ai.google.dev/gemini-api/docs
- https://ai.google.dev/gemini-api/docs/structured-output
- https://ai.google.dev/gemini-api/docs/pricing
- https://ai.google.dev/gemini-api/terms

## Cloudflare R2

Official:
- https://developers.cloudflare.com/r2/pricing/
- https://developers.cloudflare.com/r2/api/tokens/
- https://developers.cloudflare.com/r2/buckets/object-lifecycles/

Design:
- encrypted logical backup destination only
- private bucket
- age public key in CI; private key stays outside CI

## v4 additional requirements — 2026-08-19 10:54 JST

User requested scheduled household LINE operation:
- Sunday noon: send one-week schedule to both spouses
- every morning 07:00: send dropoff/pickup assignee to both
- dropoff assignee 07:00 checklist; 08:30 input reminder; LINE or PWA link
- pickup assignee 16:00 checklist; 20:30 input reminder; LINE or PWA link
- non-pickup adult 20:00 evening checklist; 22:00 input reminder; LINE or PWA link
- times/frequencies are proposals and should be configurable

v4 design refinement:
- same-minute same-recipient messages bundle
- no-item/all-complete reminders suppressed
- session model binds checklist delivery to later input
- reassignment invalidates stale session/reminder


## v6 external verification — 2026-08-19

Supabase:
- per-function verify_jwt in config.toml; default true
- Free Edge Function target 500,000 invocations/month
Official:
- https://supabase.com/docs/guides/functions/function-configuration
- https://supabase.com/docs/guides/functions/auth-headers
- https://supabase.com/docs/guides/platform/manage-your-usage/edge-function-invocations

LINE:
- retry key valid 24h; accepted same-key retry returns 409
- using same key after 24h can be treated as a new request
- Japan Communication Plan example up to 200/month; Reply API not counted
Official:
- https://developers.line.biz/en/docs/messaging-api/retrying-api-request/
- https://developers.line.biz/en/docs/messaging-api/pricing/
- https://developers.line.biz/en/faq/

Google Calendar:
- accessRole values include writerWithoutPrivateAccess/writer/owner
- v6 uses events.patch, not full events.update
- sendUpdates supports none
Official:
- https://developers.google.com/workspace/calendar/api/v3/reference/calendarList
- https://developers.google.com/workspace/calendar/api/v3/reference/events/patch
- https://developers.google.com/workspace/calendar/api/v3/reference/events/update

R2:
- free tier applies to Standard storage
Official:
- https://developers.cloudflare.com/r2/pricing/

Japan holidays:
- Cabinet Office publishes public holidays/holiday-law days and CSV
Official:
- https://www8.cao.go.jp/chosei/shukujitsu/gaiyou.html
- https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu_kyujitsu.csv

# 14. External Setup Steps — v6

Human-only setupを実装前後で明確に分離する。

## 1. Supabase

Already created:
- project name `family-ops`
- Free plan
- Tokyo region

Need:
- project link from local CLI
- frontend publishable key
- Edge Function secrets
- Vault entries
- Cron jobs after migrations

### Cron worker secret
Generate 256-bit random `CRON_WORKER_TOKEN`.
Set same value in:
1. Edge Function secrets
2. Supabase Vault value referenced by pg_net Cron headers

Never put it in VITE env/client.

## 2. GitHub

- create/connect repository `family-ops`
- protect main as desired
- CI secrets only where required
- no DB password/service secret in repo

## 3. App Google Sign-In

Supabase Auth Google provider setup for PWA login.
This is separate from Calendar OAuth credential flow.

## 4. Google Calendar OAuth

Google Cloud project/consent:
- Calendar OAuth client
- redirect URI to Family Ops callback
- exact scopes:
  - `https://www.googleapis.com/auth/calendar.events`
  - `https://www.googleapis.com/auth/calendar.calendarlist.readonly`
- confidential web-server client + state; PKCEなし in MVP
- offline access

### Critical publishing gate
During development, Testing may be used, but Calendar-scope refresh token can expire after about 7 days under Testing publishing status.

**Before family production use:**
- OAuth app publishing status = `In production`
- confirm reauth flow
- revoke/reauth test once

## 5. Family shared Google Calendar

Selection gate:
- accessRole writerWithoutPrivateAccess/writer/owner
- timeZone Asia/Tokyo
- reader/freeBusyReader rejected


- create dedicated family shared calendar if not already available
- both adults have desired edit rights
- connect one Family Ops sync-owner credential
- choose the target external_calendar_id in PWA setup

Do not migrate old TimeTree data automatically in MVP unless a separate one-time migration is approved.

## 6. Calendar task setup

Initial Family Ops setup must ask, not assume:
- typical dropoff local clock time
- typical pickup local clock time
- conflict window (default 60min)
- each weekday's dropoff assignee
- each weekday's pickup assignee
- evening routine wizard:
  - weekdays
  - strategy nonpickup_adult / pickup_assignee / fixed / disabled
  - fixed assignee when needed

## 6A. Timezone

MVPは`Asia/Tokyo`固定。
timezone変更UI/DST multi-timezone setupは作らない。
materialize Cron=00:10 JST。

## 7. LINE

- create LINE Official Account
- enable Messaging API
- set webhook URL
- configure channel secret/access token in Edge secrets
- add Official Account as friend on both phones
- each adult performs Family Ops account link flow

Test before production:
- text inbound
- postback
- scheduled push
- retry handling
- each adult LINE link uniqueness/re-link
- quota target-limit endpoint
- quota monthly-consumption endpoint
- confirm plan limit is captured into `line_quota_state`

### LINE free quota production gate
- APP_LINE_MONTHLY_HARD_CAP=200 mandatory
- provider plan increase must not increase Family Ops app cap
- parallel-send test at 199

### LINE free quota production check
- Communication Plan/free運用を使う場合、provider reported limitを管理画面で確認
- Family Ops soft budget初期180 / reserve20
- 180到達後reminderがin-app fallbackするsmoke test
- manual LINE Official Account Manager送信もprovider_consumedへ反映されるため、provider usageをlocal countより優先して観測

## 8. Scheduled LINE defaults

Initial household schedule seed:
- non-workday morning digest: Saturday/Sunday/holiday 09:00; Sunday includes next week
- daily assignment: 07:00
- dropoff checklist: 07:00
- dropoff check-in: 08:30
- pickup checklist: 16:00
- non-pickup evening checklist: 20:00
- pickup check-in: 20:30
- non-pickup evening check-in: 22:00

All shown in PWA Settings and editable after setup.

## 9. Gemini

- create Gemini API key in Google's supported developer environment
- put only in Edge secret
- model IDs env-driven
- verify quota/fallback

AI privacy is not a product blocker by user decision, but never send application secrets/token/credential into model input.

## 10. Backup / R2

- Cloudflare R2 private bucket `family-ops-backups`, **Standard storage class**
- access key ID/secret in CI
- age public key in CI
- age private key **not** in CI; owner password manager/offline storage
- restore drill target disposable/local DB

## 11. Production checklist

Before wife/partner relies on the system daily:
- Google OAuth In production
- both LINE accounts linked
- shared Calendar sync green
- dropoff/pickup times filled
- recurrence seed checked
- routine schedule times checked
- scheduled LINE smoke test
- RLS cross-household tests green
- backup/restore drill green

## 12. Account lifecycle warning

MVPではSupabase Auth user / household member hard deleteを行わない。
historical rowsがRESTRICT参照しているため、Dashboardからの直接削除は運用禁止。


## 13. Japan holiday source

Official:
`https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu_kyujitsu.csv`

Before production:
- seed 2026/2027 fixture
- run sync-jp-holidays
- verify known rows

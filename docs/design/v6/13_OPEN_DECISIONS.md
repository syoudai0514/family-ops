# 13. Open Decisions / Human Setup — v6

## 1. Implementation decisions already fixed

Sonnet must not reopen:
- DB/backend: Supabase
- App Auth: Supabase Auth Google Sign-In
- Calendar OAuth separate from App Auth
- family schedule master: Google Calendar
- LINE durable inbox/outbox
- PWA mutation entrypoint: Edge Function only
- server transaction RPC: browser execute denied
- client mutation idempotency: mutation_receipts
- Cron worker auth: CRON_WORKER_TOKEN
- Google create idempotency: deterministic client-generated event ID
- Google sync states: queued/processing/done/dead
- recurring overlap: btree_gist exclusion constraint
- all-day Google events: conflict detection excluded in MVP
- direct Google event without busy metadata: busy owner unknown
- request task creation: accept time
- request cancel: requester pending-only
- offline write: MVP no
- scheduled LINE defaults: v6 README/17 doc
- same-minute scheduled notifications: bundle
- completed scheduled session reminder: suppress
- backup: encrypted off-site logical dump + restore drill

## 2. Human values/setup still needed

These are not architecture choices; they are household settings/secrets.

1. GitHub repo and permissions
2. Supabase project link
3. Google Auth provider credentials
4. Calendar OAuth credentials
5. family shared Google Calendar
6. LINE Official Account
7. Gemini key
8. R2 bucket/access key
9. age keypair/private key custody
10. typical dropoff clock time
11. typical pickup clock time
12. initial evening task assignees
13. whether default notification times should be adjusted after a week of use

## 3. Product naming / cosmetics can remain open

- display app name
- icon/branding
- calendar display name
- exact emoji/message wording

These must not block schema/API.

## 4. AI policy

- Gemini free remains in MVP
- privacy concern alone is not blocker per user direction
- raw partner text remains private by product semantics
- no AI auto-send without sender confirmation for partner request/handover


## v6 decisions closed

Not open:
- verify_jwt routing
- LINE hard cap/retry lifetime
- Google PATCH/accessRole/timezone
- recurring identity
- busy classification normalization
- weekend/holiday cadence

# Family Ops — Operational Runbook

## LINE production setup: Webhook redelivery must be turned ON

Before linking a real LINE Official Account for production use, the
**Webhook redelivery** toggle in the LINE Developers Console (Messaging API
channel settings) is a mandatory checklist item — not optional, not a
"nice to have." This repo's LINE ingestion design depends on it:

- `line-webhook-receiver` (`supabase/functions/line-webhook-receiver/index.ts`)
  returns a non-2xx status whenever it cannot durably persist the inbound
  event (see `docs/design/v6/06_LINE_INTEGRATION.md` "13. Failure/recovery"
  and the v6 review fix P1-3 in this repo's history: the webhook must never
  ack `200` on a DB persistence failure it cannot guarantee happened).
- The entire retry/idempotency contract this repo implements — durable
  `private.webhook_inbox`, `provider_event_id` dedup, lease/reclaim,
  `LINE_RETRY_CASES` fixture scenarios — only has anything to recover
  *from* if LINE's platform actually retries a failed delivery. If Webhook
  redelivery is left OFF, a transient failure (worker restart, brief DB
  unavailability, a deploy in flight) causes LINE to silently drop that
  webhook call forever: no retry ever arrives, and the durable-inbox /
  retry-key machinery in this codebase never gets a second chance to run.
- This is exactly the "webhook redelivery" test scenario listed in
  `docs/design/v6/06_LINE_INTEGRATION.md` #14 ("Tests") — that scenario is
  meaningless against a real LINE Official Account unless this setting is
  on before go-live.

**Production go-live checklist requirement**: confirm Webhook redelivery is
**ON** in the LINE Developers Console for the production channel, and
verify it with a real forced-failure test (e.g. temporarily point the
webhook URL at an endpoint that 5xxs, confirm LINE retries) before
accepting real user traffic. Re-verify after any LINE channel
recreation/migration, since this setting is not carried over automatically.

## Never hard-delete an `auth.users` row from the Supabase Dashboard

MVP does not support hard-deleting an authenticated user or household
member. This is an explicit v6 policy
(`docs/design/v6/04_SECURITY_RLS_PRIVACY.md` "v6 account deletion policy",
`docs/design/v6/15_DDL_CONTRACT.md` #4), not an oversight:

- `auth.users -> public.profiles` and `auth.users -> public.household_members`
  are `ON DELETE CASCADE`, so deleting a user *does* remove their profile and
  household membership row.
- Every table that references a household member — historical/business data
  (`task_instances`, `task_events`, `requests`, `handover_reads`,
  `shopping_items`, ...) as well as household-level settings created at
  bootstrap time (`household_routine_schedules.updated_by`,
  `notification_preferences`) — has **no** `ON DELETE` clause, which
  defaults to `RESTRICT` in PostgreSQL.

The practical effect: deleting an `auth.users` row cascades one level down to
`household_members`, then fails there with a foreign-key violation and the
whole `DELETE` rolls back — **on purpose, and unconditionally** once that
user has ever created or joined a household. This isn't a "sometimes"
protection that only kicks in after enough task history piles up:
`server_tx_create_household` itself seeds `household_routine_schedules` and
`notification_preferences` rows referencing the creator in the same
transaction, so there is no window where a household exists but its creator
could still be cleanly hard-deleted. A brand-new `auth.users` row that never
joined any household (so nothing references it at all) is the only case
that deletes cleanly.

`tests/sql/09_hard_delete_restrict.sql` proves both shapes: a user with no
household ties deletes cleanly; a user who just created a household (before
any task/request ever existed) and a user with real task history are both
rejected with `foreign_key_violation`, and nothing is left partially
deleted.

If a real account-deletion feature is ever built, it needs its own
anonymize/soft-lifecycle design — not a hard delete — per the v6 policy
above. Until then: **do not** delete rows from `auth.users` directly via the
Supabase Dashboard for any user who has ever created or joined a household.

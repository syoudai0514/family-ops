# Family Ops — Operational Runbook (WP1)

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

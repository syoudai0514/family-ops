-- v6 review fix (P1-5): status/lease CHECK constraints for the remaining
-- queue tables, matching the pattern already used for
-- private.google_sync_jobs (20260819000005) and the general rule in
-- docs/design/v6/15_DDL_CONTRACT.md #7 "queue":
--   "processing/sending/executing lease requires owner/token/until"
--   "terminal state clears lease"

alter table private.webhook_inbox
  add constraint webhook_inbox_lease_requires_processing
    check (status = 'processing' or (lease_owner is null and lease_token is null and lease_until is null)),
  add constraint webhook_inbox_processing_requires_lease
    check (status <> 'processing' or (lease_owner is not null and lease_token is not null and lease_until is not null));

alter table private.notification_outbox
  add constraint notification_outbox_lease_requires_sending
    check (status = 'sending' or (lease_owner is null and lease_token is null and lease_until is null)),
  add constraint notification_outbox_sending_requires_lease
    check (status <> 'sending' or (lease_owner is not null and lease_token is not null and lease_until is not null));

alter table private.pending_actions
  add constraint pending_actions_lease_requires_executing
    check (status = 'executing' or (lease_owner is null and lease_token is null and lease_until is null)),
  add constraint pending_actions_executing_requires_lease
    check (status <> 'executing' or (lease_owner is not null and lease_token is not null and lease_until is not null));

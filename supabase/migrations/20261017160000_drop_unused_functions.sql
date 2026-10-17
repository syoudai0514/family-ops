-- Functions nothing calls any more (checked 2026-10-17: no Edge Function, web code,
-- SQL function body, trigger, event trigger or cron job references them).
--  * default_schedule_reminders(boolean): replaced by the household-aware
--    default_schedule_reminders(uuid, boolean) in 20261017120000.
--  * The request adapters below were superseded by server_tx_transition_request_v2,
--    which accept-assignment-change-request / negotiate-request / respond-request call.
--  * fn_activate_family_event_provider_writer_v1 was never wired to a caller.
drop function if exists public.default_schedule_reminders(boolean);
drop function if exists public.server_tx_accept_assignment_change_request(uuid, uuid, uuid);
drop function if exists public.server_tx_negotiate_request_v1(uuid, uuid, uuid, uuid, text, jsonb, bigint, integer);
drop function if exists public.server_tx_respond_request(uuid, uuid, uuid, text);
drop function if exists private.fn_activate_family_event_provider_writer_v1(uuid, uuid, uuid);

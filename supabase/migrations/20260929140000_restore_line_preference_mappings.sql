-- Restore the notification-type -> LINE-preference mappings that
-- 20260916090000_codmon_daily_submission dropped.
--
-- That migration re-declared private.fn_line_preference_column_for_type() in
-- full to add 'codmon.deadline', but wrote the new body from a shorter list
-- than the version it replaced (20260903030002). Five types that live code
-- still emits silently fell through to `else null`:
--
--   daily_brief.v2             -> daily_assignment_line   (morning/evening brief)
--   request.followup_requested -> request_line
--   request.followup_declined  -> request_line
--   shopping.handled_neutral   -> shopping_minor_line
--   shopping.reopened_neutral  -> shopping_minor_line
--
-- Why that is invisible: private.fn_enqueue_line_notification() returns without
-- doing anything when this function returns NULL. The in-app notification is
-- still created, the trigger raises nothing, and no row ever reaches
-- private.notification_outbox -- so from 2026-09-16 the daily briefs stopped
-- reaching LINE while everything upstream and downstream kept reporting
-- success. Only the 09:00 codmon reminder (which the new body did map) kept
-- arriving.
--
-- Nothing is backfilled: a brief's business_expires_at is about eight hours,
-- so a missed brief is stale by the time anyone could resend it. Delivery
-- resumes with the next brief once this is applied.
--
-- The body below is the union of the 20260903030002 mapping and the current
-- codmon mapping. `create or replace` of a whole body is what caused this, so
-- tests/sql/94_line_preference_mapping_regression.sql pins every type.

create or replace function private.fn_line_preference_column_for_type(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'request_received' then 'request_line'
    when 'request_accepted' then 'request_line'
    when 'request_declined' then 'request_line'
    when 'handover_created' then 'handover_line'
    when 'request.received' then 'request_line'
    when 'request.checking' then 'request_line'
    when 'request.accepted' then 'request_line'
    when 'request.declined' then 'request_line'
    when 'request.cancelled' then 'request_line'
    when 'request.followup_requested' then 'request_line'
    when 'request.followup_declined' then 'request_line'
    when 'task.completed_neutral' then 'routine_completion_line'
    when 'shopping.handled_neutral' then 'shopping_minor_line'
    when 'shopping.reopened_neutral' then 'shopping_minor_line'
    when 'daily_brief.v2' then 'daily_assignment_line'
    when 'codmon.deadline' then 'routine_checkin_prompt_line'
    else null
  end;
$$;

revoke all on function private.fn_line_preference_column_for_type(text)
  from public, anon, authenticated;
grant execute on function private.fn_line_preference_column_for_type(text)
  to service_role;

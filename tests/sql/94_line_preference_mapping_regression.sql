-- Regression: 20260916090000_codmon_daily_submission re-declared
-- private.fn_line_preference_column_for_type() from a shorter list and dropped
-- 'daily_brief.v2' (plus four other live types). The enqueue trigger returns
-- silently on NULL, so LINE delivery of the daily briefs stopped with no error
-- anywhere. Every type below is emitted by live code and must stay mapped.
\set ON_ERROR_STOP on

begin;
set role service_role;

do $$
declare
  v_expected constant jsonb := '{
    "request_received":            "request_line",
    "request_accepted":            "request_line",
    "request_declined":            "request_line",
    "handover_created":            "handover_line",
    "request.received":            "request_line",
    "request.checking":            "request_line",
    "request.accepted":            "request_line",
    "request.declined":            "request_line",
    "request.cancelled":           "request_line",
    "request.followup_requested":  "request_line",
    "request.followup_declined":   "request_line",
    "task.completed_neutral":      "routine_completion_line",
    "shopping.handled_neutral":    "shopping_minor_line",
    "shopping.reopened_neutral":   "shopping_minor_line",
    "daily_brief.v2":              "daily_assignment_line",
    "codmon.deadline":             "routine_checkin_prompt_line"
  }';
  v_type text;
  v_column text;
  v_actual text;
begin
  for v_type, v_column in select key, value #>> '{}' from jsonb_each(v_expected) loop
    v_actual := private.fn_line_preference_column_for_type(v_type);
    if v_actual is distinct from v_column then
      raise exception 'type % maps to % (expected %): LINE delivery for it is silently dropped',
        v_type, coalesce(v_actual, 'NULL'), v_column;
    end if;

    -- A typo'd column would make the mapping look right and still never match a
    -- real preference, so the target must be an actual preference column.
    if not exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'notification_preferences'
        and column_name = v_column
    ) then
      raise exception 'type % maps to %, which is not a notification_preferences column', v_type, v_column;
    end if;
  end loop;

  -- Unknown types must still fall through to NULL (no preference, no LINE push).
  if private.fn_line_preference_column_for_type('not.a.real.type') is not null then
    raise exception 'unknown notification types must not map to a preference column';
  end if;
end $$;

rollback;

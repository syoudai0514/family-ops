-- Contract/schema lint: every documented unique/FK/index/column referenced
-- by the mutation contract must actually exist. docs/design/v6/15_DDL_CONTRACT.md #24
\set ON_ERROR_STOP on

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'private' and table_name = 'webhook_inbox' and column_name = 'provider_event_id'
  ) then
    raise exception 'FAIL schema-lint: private.webhook_inbox.provider_event_id missing (exact spelling required)';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'private' and table_name = 'webhook_inbox' and column_name = 'event_id'
  ) then
    raise exception 'FAIL schema-lint: private.webhook_inbox.event_id must not exist (wrong spelling)';
  end if;

  if not exists (
    select 1 from pg_extension where extname = 'btree_gist'
  ) then
    raise exception 'FAIL schema-lint: btree_gist extension not installed';
  end if;

  if not exists (
    select 1 from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public' and t.relname = 'recurrence_rules' and c.contype = 'x'
  ) then
    raise exception 'FAIL schema-lint: recurrence_rules exclusion constraint missing';
  end if;

  if not exists (
    select 1 from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public' and t.relname = 'households' and c.contype = 'c'
      and pg_get_constraintdef(c.oid) ilike '%Asia/Tokyo%'
  ) then
    raise exception 'FAIL schema-lint: households.timezone CHECK Asia/Tokyo missing';
  end if;

  if not exists (
    select 1 from information_schema.table_constraints
    where table_schema = 'public' and table_name = 'household_members'
      and constraint_type = 'UNIQUE'
  ) then
    raise exception 'FAIL schema-lint: household_members UNIQUE(user_id) missing';
  end if;
end;
$$;

-- P1-1: weekly_digest / Sunday 12:00 must never come back as a valid
-- schedule_kind; the 9-kind non-workday model must be exactly what the
-- CHECK constraint allows.
do $$
declare
  v_def text;
begin
  select pg_get_constraintdef(c.oid) into v_def
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'public' and t.relname = 'household_routine_schedules'
    and c.contype = 'c' and pg_get_constraintdef(c.oid) ilike '%schedule_kind%';

  if v_def is null then
    raise exception 'FAIL schema-lint: household_routine_schedules.schedule_kind CHECK missing';
  end if;
  if v_def ilike '%weekly_digest%' then
    raise exception 'FAIL schema-lint: weekly_digest must not be an allowed schedule_kind (retired)';
  end if;
  if v_def not ilike '%nonworkday_morning_digest%' or v_def not ilike '%nonworkday_checkin%' then
    raise exception 'FAIL schema-lint: nonworkday_morning_digest/nonworkday_checkin must be allowed schedule_kind values';
  end if;
end;
$$;

-- every documented private table exists (15_DDL_CONTRACT.md #18)
do $$
declare
  t text;
  required text[] := array[
    'webhook_inbox', 'line_user_links', 'pending_actions', 'raw_inputs',
    'household_invites', 'line_link_tokens', 'google_oauth_states',
    'notification_outbox', 'line_quota_state', 'line_quota_reservations',
    'google_event_staging', 'google_connections', 'google_watch_channels',
    'google_sync_state', 'google_sync_jobs', 'google_write_operations',
    'mutation_receipts', 'scheduled_dispatch_receipts', 'jp_holidays'
  ];
begin
  foreach t in array required loop
    if not exists (
      select 1 from information_schema.tables
      where table_schema = 'private' and table_name = t
    ) then
      raise exception 'FAIL schema-lint: private.% missing', t;
    end if;
  end loop;
end;
$$;

-- No function in public/private ever ends up EXECUTE-able by PUBLIC
-- (anon/authenticated get only the explicit, narrow grants added per
-- function; see 20260819000010's comment for why this needs to be an
-- explicit assertion rather than trusted default-privilege behavior).
do $$
declare
  r record;
begin
  for r in
    select n.nspname as schema_name, p.proname as function_name
    from information_schema.role_routine_grants g
    join pg_proc p on p.proname = g.routine_name
    join pg_namespace n on n.oid = p.pronamespace and n.nspname = g.routine_schema
    where g.routine_schema in ('public', 'private')
      and g.grantee = 'PUBLIC'
  loop
    raise exception 'FAIL schema-lint: %.% is EXECUTE-able by PUBLIC', r.schema_name, r.function_name;
  end loop;
end;
$$;

select 'schema_lint: PASS' as result;

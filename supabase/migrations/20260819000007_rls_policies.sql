-- WP1: Row Level Security for every public table
-- docs/design/v6/04_SECURITY_RLS_PRIVACY.md; fixtures/RLS_POLICY_MATRIX.md
--
-- Pattern for every household-owned table:
--   - authenticated gets GRANT SELECT only (never INSERT/UPDATE/DELETE)
--   - SELECT policy restricts rows to the caller's own household
--   - all state mutation happens via Edge Function -> public.server_tx_*
--     (SECURITY INVOKER, EXECUTE revoked from anon/authenticated; see
--     20260819000009_server_tx_functions.sql)
-- anon gets nothing on any business table.

-- ---------------------------------------------------------------------------
-- Read helper: authenticated may call this (auth.uid()-driven only, never
-- accepts a caller-supplied actor id as a trust input).
--
-- SECURITY DEFINER is unavoidable here (04_SECURITY_RLS_PRIVACY.md #5 allows
-- it "only if unavoidable"): household_members' own SELECT policy calls this
-- function, and household_members itself has RLS enabled, so a SECURITY
-- INVOKER helper would re-trigger that same policy on its internal query and
-- recurse infinitely ("stack depth limit exceeded"). Running as the function
-- owner (a superuser in every environment this migrates to) bypasses RLS for
-- that one internal lookup, breaking the cycle. The function only ever
-- returns a boolean derived from auth.uid() against a fixed, parameterized
-- query — it accepts no dynamic SQL and never accepts a caller-supplied
-- actor id as a trust input.
-- ---------------------------------------------------------------------------

create or replace function public.is_household_member(target_household_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.household_members m
    where m.household_id = target_household_id
      and m.user_id = auth.uid()
  );
$$;

grant execute on function public.is_household_member(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- households
-- ---------------------------------------------------------------------------

alter table public.households enable row level security;
grant select on public.households to authenticated;
create policy households_select on public.households
  for select to authenticated
  using (public.is_household_member(id));

-- ---------------------------------------------------------------------------
-- profiles (self or same-household adults; no direct client mutation)
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
grant select on public.profiles to authenticated;
create policy profiles_select on public.profiles
  for select to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1
      from public.household_members me
      join public.household_members them on them.household_id = me.household_id
      where me.user_id = auth.uid()
        and them.user_id = profiles.user_id
    )
  );

-- ---------------------------------------------------------------------------
-- household_members (same household read; server-only mutation)
-- ---------------------------------------------------------------------------

alter table public.household_members enable row level security;
grant select on public.household_members to authenticated;
create policy household_members_select on public.household_members
  for select to authenticated
  using (public.is_household_member(household_id));

-- ---------------------------------------------------------------------------
-- Generic household-scoped READ-HH / SERVER-MUTATION tables
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
  tables text[] := array[
    'task_definitions',
    'task_subtask_definitions',
    'recurrence_rules',
    'task_instances',
    'task_subtask_instances',
    'task_events',
    'requests',
    'handovers',
    'shopping_items',
    'household_routine_schedules',
    'routine_checkin_sessions',
    'routine_checkin_session_items',
    'calendar_connections',
    'calendar_events_cache',
    'calendar_event_occurrences',
    'calendar_occurrence_busy_members',
    'calendar_busy_classifications',
    'calendar_busy_classification_members',
    'evening_routine_preferences'
  ];
begin
  foreach t in array tables loop
    execute format('alter table public.%I enable row level security', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.is_household_member(household_id))',
      t || '_select', t
    );
  end loop;
end;
$$;

-- handover_reads (kept out of the generic loop only because its primary key
-- is (handover_id, user_id) rather than a surrogate id; same READ HH shape).
alter table public.handover_reads enable row level security;
grant select on public.handover_reads to authenticated;
create policy handover_reads_select on public.handover_reads
  for select to authenticated
  using (public.is_household_member(household_id));

-- ---------------------------------------------------------------------------
-- user_notifications (recipient-only read; insert/mark-read server only)
-- ---------------------------------------------------------------------------

alter table public.user_notifications enable row level security;
grant select on public.user_notifications to authenticated;
create policy user_notifications_select on public.user_notifications
  for select to authenticated
  using (recipient_user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- notification_preferences (self read; self mutation is server-mediated)
-- ---------------------------------------------------------------------------

alter table public.notification_preferences enable row level security;
grant select on public.notification_preferences to authenticated;
create policy notification_preferences_select on public.notification_preferences
  for select to authenticated
  using (user_id = auth.uid());

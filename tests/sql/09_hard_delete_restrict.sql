-- v6 review fix (P2): auth user hard delete cascade alignment.
-- docs/design/v6/04_SECURITY_RLS_PRIVACY.md "v6 account deletion policy":
-- "MVP does not support hard-deleting an auth user / household member,
-- because historical FKs RESTRICT it." That is a blanket MVP policy, not a
-- "sometimes" — this file proves the RESTRICT chain actually enforces it in
-- both the shape that matters: a user with zero household ties deletes
-- cleanly (nothing to protect), but the moment a user has ever created a
-- household — even seconds ago, before any task/request/etc. — the DB
-- refuses to hard-delete them, because household setup itself
-- (notification_preferences, household_routine_schedules) already
-- references them. See docs/RUNBOOK.md.
\set ON_ERROR_STOP on

set role service_role;

-- an auth user with no household ties at all (never signed up for one)
-- deletes cleanly — there is nothing referencing them
do $$
declare
  v_user uuid := 'a9000000-0000-0000-0000-000000000001';
begin
  insert into auth.users (id) values (v_user);
  delete from auth.users where id = v_user;

  if exists (select 1 from auth.users where id = v_user) then
    raise exception 'FAIL hard-delete: a user with no household ties should delete cleanly';
  end if;
end;
$$;

-- the moment a user creates a household, MVP hard delete is blocked — even
-- with zero task/request/shopping/handover history — because household
-- bootstrap itself (household_routine_schedules.updated_by,
-- notification_preferences) already references them
do $$
declare
  v_hh jsonb;
  v_user uuid := 'a9000000-0000-0000-0000-000000000002';
begin
  insert into auth.users (id) values (v_user);
  v_hh := public.server_tx_create_household(v_user, gen_random_uuid(), 'Fresh HH', 'Owner');

  begin
    delete from auth.users where id = v_user;
    raise exception 'FAIL hard-delete: deleting a fresh household''s creator must still be rejected (MVP does not support hard delete)';
  exception
    when foreign_key_violation then null; -- expected
  end;

  if not exists (select 1 from auth.users where id = v_user) then
    raise exception 'FAIL hard-delete: auth.users row must still exist after the rejected delete';
  end if;
  if not exists (select 1 from public.household_members where user_id = v_user) then
    raise exception 'FAIL hard-delete: household_members row must still exist after the rejected delete';
  end if;
end;
$$;

-- a user with genuine business history (a task_events row) is blocked the
-- same way, for the same reason
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_user uuid := 'a9000000-0000-0000-0000-000000000003';
  v_task_def uuid;
  v_task_instance uuid;
begin
  insert into auth.users (id) values (v_user);
  v_hh := public.server_tx_create_household(v_user, gen_random_uuid(), 'History Guard HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  -- 'dishes' is now bootstrapped automatically by server_tx_create_household
  -- (P1 #3) — reuse it instead of inserting a conflicting duplicate code.
  select id into v_task_def from public.task_definitions where household_id = v_hh_id and code = 'dishes';

  insert into public.task_instances
    (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date, completion_mode, status, source, created_by)
  values
    (v_hh_id, v_task_def, 'manual', 'Dishes', 'chore', 'anytime', current_date, 'whole', 'todo', 'manual', v_user)
  returning id into v_task_instance;

  insert into public.task_events (household_id, task_instance_id, actor_id, event_type, source)
  values (v_hh_id, v_task_instance, v_user, 'created', 'pwa');

  begin
    delete from auth.users where id = v_user;
    raise exception 'FAIL hard-delete: deleting a user with historical task_events must be rejected';
  exception
    when foreign_key_violation then null; -- expected
  end;

  if not exists (select 1 from public.task_events where actor_id = v_user) then
    raise exception 'FAIL hard-delete: task_events history must be untouched after the rejected delete';
  end if;
end;
$$;

reset role;

select 'hard_delete_restrict: PASS' as result;

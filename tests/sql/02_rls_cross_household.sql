-- RLS cross-household isolation + direct mutation denial + private schema
-- unreachability. docs/design/v6/04_SECURITY_RLS_PRIVACY.md #14;
-- fixtures/RLS_POLICY_MATRIX.md "Mandatory tests"
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- Fixtures (as postgres superuser, bypasses RLS)
-- ---------------------------------------------------------------------------

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'), -- household A adult 1
  ('22222222-2222-2222-2222-222222222222'), -- household A adult 2
  ('33333333-3333-3333-3333-333333333333'), -- household B adult 1
  ('44444444-4444-4444-4444-444444444444'); -- unaffiliated user

insert into public.households (id, name) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Household A'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Household B');

insert into public.profiles (user_id, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'A1'),
  ('22222222-2222-2222-2222-222222222222', 'A2'),
  ('33333333-3333-3333-3333-333333333333', 'B1'),
  ('44444444-4444-4444-4444-444444444444', 'Unaffiliated');

insert into public.household_members (household_id, user_id, member_role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'adult'),
  ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'adult'),
  ('bbbbbbbb-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333', 'adult');

insert into public.task_definitions (id, household_id, code, title, category, completion_mode, created_by)
values
  ('aaaaaaaa-1111-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'dishes', 'Dishes', 'chore', 'whole', '11111111-1111-1111-1111-111111111111'),
  ('bbbbbbbb-1111-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000002', 'dishes', 'Dishes', 'chore', 'whole', '33333333-3333-3333-3333-333333333333');

insert into public.task_instances
  (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date, completion_mode, status, source, created_by)
values
  ('aaaaaaaa-2222-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-1111-0000-0000-000000000001', 'manual', 'Dishes', 'chore', 'anytime', current_date, 'whole', 'todo', 'manual', '11111111-1111-1111-1111-111111111111'),
  ('bbbbbbbb-2222-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000002', 'bbbbbbbb-1111-0000-0000-000000000002', 'manual', 'Dishes', 'chore', 'anytime', current_date, 'whole', 'todo', 'manual', '33333333-3333-3333-3333-333333333333');

insert into public.user_notifications (household_id, recipient_user_id, type, title, body, dedup_key)
values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'test', 'Hi A1', 'body', 'dedup-a1'),
  ('bbbbbbbb-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333', 'test', 'Hi B1', 'body', 'dedup-b1');

-- ---------------------------------------------------------------------------
-- 1. Household A member sees only household A rows
-- ---------------------------------------------------------------------------

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
set request.jwt.claim.role = 'authenticated';

do $$
declare v_count int;
begin
  select count(*) into v_count from public.households;
  if v_count <> 1 then
    raise exception 'FAIL rls: household A member should see exactly 1 household, saw %', v_count;
  end if;

  select count(*) into v_count from public.task_instances;
  if v_count <> 1 then
    raise exception 'FAIL rls: household A member should see exactly 1 task_instance, saw %', v_count;
  end if;

  select count(*) into v_count from public.task_instances where household_id = 'bbbbbbbb-0000-0000-0000-000000000002';
  if v_count <> 0 then
    raise exception 'FAIL rls: household A member must not see household B task_instances';
  end if;

  select count(*) into v_count from public.household_members;
  if v_count <> 2 then
    raise exception 'FAIL rls: household A member should see 2 household_members rows (own household only), saw %', v_count;
  end if;

  -- recipient-only table: A1 sees only their own notification, never B1's
  select count(*) into v_count from public.user_notifications;
  if v_count <> 1 then
    raise exception 'FAIL rls: user_notifications must be recipient-scoped, saw %', v_count;
  end if;
end;
$$;

-- 2. Direct client mutation on business tables is denied (no privilege at all)
do $$
begin
  begin
    insert into public.task_instances
      (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date, completion_mode, status, source, created_by)
    values
      ('aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-1111-0000-0000-000000000001', 'manual', 'spoof', 'chore', 'anytime', current_date, 'whole', 'todo', 'manual', '11111111-1111-1111-1111-111111111111');
    raise exception 'FAIL rls: authenticated INSERT on task_instances should have been denied';
  exception
    when insufficient_privilege then
      null; -- expected
  end;
end;
$$;

do $$
begin
  begin
    update public.households set name = 'spoofed' where id = 'aaaaaaaa-0000-0000-0000-000000000001';
    raise exception 'FAIL rls: authenticated UPDATE on households should have been denied';
  exception
    when insufficient_privilege then
      null; -- expected
  end;
end;
$$;

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

-- ---------------------------------------------------------------------------
-- 3. anon sees nothing on business tables
-- ---------------------------------------------------------------------------

set role anon;
do $$
begin
  begin
    perform 1 from public.households limit 1;
    raise exception 'FAIL rls: anon SELECT on households should have been denied';
  exception
    when insufficient_privilege then
      null;
  end;
end;
$$;
reset role;

-- ---------------------------------------------------------------------------
-- 4. private schema is unreachable to anon/authenticated
-- ---------------------------------------------------------------------------

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
do $$
begin
  begin
    perform 1 from private.line_user_links limit 1;
    raise exception 'FAIL rls: authenticated must not be able to select private.line_user_links';
  exception
    when insufficient_privilege then null;
    when invalid_schema_name then null;
  end;
end;
$$;
reset role;
reset request.jwt.claim.sub;

-- ---------------------------------------------------------------------------
-- 5. Cross-household FK/composite-key integrity at the DB level (service-side
--    bug simulation: even service_role cannot insert a cross-household ref)
-- ---------------------------------------------------------------------------

set role service_role;
do $$
begin
  begin
    -- household A task assigned to a household B member must fail FK
    insert into public.task_instances
      (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
       planned_assignee_id, completion_mode, status, source, created_by)
    values
      ('aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-1111-0000-0000-000000000001', 'manual', 'cross-hh', 'chore', 'anytime',
       current_date, '33333333-3333-3333-3333-333333333333', 'whole', 'todo', 'manual', '11111111-1111-1111-1111-111111111111');
    raise exception 'FAIL rls: cross-household planned_assignee_id must fail composite FK';
  exception
    when foreign_key_violation then null;
  end;
end;
$$;

do $$
begin
  begin
    -- household A handover read by a household B user must fail composite FK
    insert into public.handovers (household_id, author_id, shared_text, period, occurred_on)
    values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'shared', 'evening', current_date);

    insert into public.handover_reads (household_id, handover_id, user_id, read_at)
    select 'aaaaaaaa-0000-0000-0000-000000000001', id, '33333333-3333-3333-3333-333333333333', now()
    from public.handovers
    where household_id = 'aaaaaaaa-0000-0000-0000-000000000001'
    limit 1;
    raise exception 'FAIL rls: cross-household handover_reads.user_id must fail composite FK';
  exception
    when foreign_key_violation then null;
  end;
end;
$$;
reset role;

select 'rls_cross_household: PASS' as result;

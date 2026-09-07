-- Issue #54: unplanned actual is atomic, idempotent, and keeps the original
-- target date distinct from the audit completion timestamp.
\set ON_ERROR_STOP on

insert into auth.users (id) values ('79000000-0000-0000-0000-000000000001');
set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_op uuid := '79000000-0000-4000-8000-000000000010';
  v_first jsonb;
  v_replay jsonb;
  v_task_id uuid;
  v_row public.task_instances%rowtype;
  v_actor_ref uuid;
begin
  v_hh := public.server_tx_create_household(
    '79000000-0000-0000-0000-000000000001',
    '79000000-0000-4000-8000-000000000002',
    'Issue54 Actual HH',
    'Owner'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;

  v_first := public.server_tx_record_unplanned_actual(
    '79000000-0000-0000-0000-000000000001',
    v_op,
    '掃除機',
    date '2026-09-06'
  );
  v_task_id := (v_first->>'task_id')::uuid;
  if v_task_id is null then
    raise exception 'FAIL issue54-actual: task_id is required';
  end if;

  select * into v_row from public.task_instances where id = v_task_id;
  if v_row.household_id <> v_hh_id
     or v_row.status <> 'completed'
     or v_row.origin <> 'manual'
     or v_row.scheduled_date <> date '2026-09-06'
     or v_row.completed_at is null
     or v_row.calendar_visibility <> 'hidden' then
    raise exception 'FAIL issue54-actual: canonical completed row/target-date shape mismatch';
  end if;

  select id into v_actor_ref
  from public.domain_actor_refs
  where household_id = v_hh_id
    and actor_kind = 'real_user'
    and real_user_id = '79000000-0000-0000-0000-000000000001';
  if v_actor_ref is null or not exists (
    select 1 from public.task_actual_participants
    where household_id = v_hh_id
      and task_instance_id = v_task_id
      and actor_ref_id = v_actor_ref
      and source = 'canonical'
  ) then
    raise exception 'FAIL issue54-actual: canonical actual participant missing';
  end if;

  v_replay := public.server_tx_record_unplanned_actual(
    '79000000-0000-0000-0000-000000000001',
    v_op,
    '掃除機',
    date '2026-09-06'
  );
  if (v_replay->>'task_id')::uuid <> v_task_id then
    raise exception 'FAIL issue54-actual: replay must return the same task';
  end if;
  if (select count(*) from public.task_instances where household_id = v_hh_id and title = '掃除機') <> 1 then
    raise exception 'FAIL issue54-actual: replay created a duplicate task';
  end if;

  begin
    perform public.server_tx_record_unplanned_actual(
      '79000000-0000-0000-0000-000000000001', v_op, '別タイトル', date '2026-09-06'
    );
    raise exception 'FAIL issue54-actual: idempotency conflict was not rejected';
  exception when others then
    if sqlerrm <> 'IDEMPOTENCY_CONFLICT' then
      raise exception 'FAIL issue54-actual: expected IDEMPOTENCY_CONFLICT, got %', sqlerrm;
    end if;
  end;
end;
$$;

reset role;
set role authenticated;
set request.jwt.claim.sub = '79000000-0000-0000-0000-000000000001';
do $$
begin
  begin
    perform public.server_tx_record_unplanned_actual(
      '79000000-0000-0000-0000-000000000001', gen_random_uuid(), 'x', current_date
    );
    raise exception 'FAIL issue54-actual: authenticated role must not call RPC directly';
  exception when insufficient_privilege then null;
  end;
end;
$$;
reset role;
reset request.jwt.claim.sub;

select 'issue54_unplanned_actual_atomic: PASS' as result;

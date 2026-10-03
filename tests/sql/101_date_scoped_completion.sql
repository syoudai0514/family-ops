-- The day navigator and LINE correction use the existing canonical completion
-- contract. Past scheduled days and early completion must retain their day.
\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  actor uuid := gen_random_uuid();
  household uuid;
  target uuid;
  local_today date := (now() at time zone 'Asia/Tokyo')::date;
  scheduled date;
  result jsonb;
begin
  insert into auth.users(id) values(actor);
  household := (public.server_tx_create_household(actor, gen_random_uuid(), 'Date completion test', 'Owner')->>'household_id')::uuid;
  foreach scheduled in array array[local_today - 2, local_today + 2] loop
    target := (public.server_tx_create_task(actor, gen_random_uuid(), 'Date-specific actual', 'chore', scheduled, null, actor, 'whole', 'anytime', null)->>'task_id')::uuid;
    result := public.server_tx_complete_task(actor, gen_random_uuid(), target, 'self', false, 'line');
    if not exists(select 1 from public.task_instances where id=target
      and household_id=household and scheduled_date=scheduled and status='completed'
      and actual_completed_by_id=actor and completed_at=now()) then
      raise exception 'FAIL past/future completion must retain scheduled date and record actual update time: %', result;
    end if;
  end loop;
end;
$$;
reset role;
rollback;
select 'date_scoped_completion: PASS' as result;

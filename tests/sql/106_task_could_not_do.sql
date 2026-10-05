-- Owner 2026-10-05: "今日詩乃の薬あげるの忘れちゃった" is recorded as できなかった,
-- kept apart from 未記録 (an open todo), and a mistaken tap can be undone.
\set ON_ERROR_STOP on

begin;

insert into auth.users(id) values
  ('10600000-0000-0000-0000-000000000001'),
  ('10600000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_hh_id uuid;
  v_task_id uuid;
  v_done_id uuid;
  v_result jsonb;
  v_op uuid := gen_random_uuid();
  v_failed boolean;
  v_t public.task_instances%rowtype;
begin
  v_hh_id:=(public.server_tx_create_household(
    '10600000-0000-0000-0000-000000000001',gen_random_uuid(),'Could Not Do HH','Owner'
  )->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role)
  values(v_hh_id,'10600000-0000-0000-0000-000000000002','adult');

  v_task_id:=(public.server_tx_create_task(
    '10600000-0000-0000-0000-000000000001',gen_random_uuid(),
    '詩乃（便秘）の薬','chore',(now() at time zone 'Asia/Tokyo')::date,
    null,'10600000-0000-0000-0000-000000000001','whole','morning',null
  )->>'task_id')::uuid;

  v_result:=public.server_tx_mark_task_could_not_do_v1('10600000-0000-0000-0000-000000000001',v_op,v_task_id,false,'line');
  select * into v_t from public.task_instances where id=v_task_id;
  if v_t.status<>'skipped' or v_t.outcome_reason is distinct from 'could_not_do' or v_t.completed_at is not null then
    raise exception 'FAIL could-not-do: must be skipped/could_not_do, got %/%', v_t.status, v_t.outcome_reason;
  end if;
  if not exists(select 1 from public.task_events where task_instance_id=v_task_id and event_type='skipped'
                and payload->>'outcome_reason'='could_not_do' and source='line') then
    raise exception 'FAIL could-not-do: the event must be kept in history';
  end if;

  -- Replay returns the same answer, without a second event.
  if public.server_tx_mark_task_could_not_do_v1('10600000-0000-0000-0000-000000000001',v_op,v_task_id,false,'line')<>v_result
     or (select count(*) from public.task_events where task_instance_id=v_task_id and event_type='skipped')<>1 then
    raise exception 'FAIL could-not-do: replay must be idempotent';
  end if;

  -- Undo: back to an open todo (the partner can still do it).
  perform public.server_tx_mark_task_could_not_do_v1('10600000-0000-0000-0000-000000000002',gen_random_uuid(),v_task_id,true,'pwa');
  select * into v_t from public.task_instances where id=v_task_id;
  if v_t.status<>'todo' or v_t.outcome_reason is not null then
    raise exception 'FAIL could-not-do undo: must return to todo';
  end if;

  -- A completed task is not turned into できなかった.
  v_done_id:=(public.server_tx_create_task(
    '10600000-0000-0000-0000-000000000001',gen_random_uuid(),
    '朝ごはん','chore',(now() at time zone 'Asia/Tokyo')::date,
    null,'10600000-0000-0000-0000-000000000001','whole','morning',null
  )->>'task_id')::uuid;
  perform public.server_tx_complete_task('10600000-0000-0000-0000-000000000001',gen_random_uuid(),v_done_id,'self',false);
  v_failed:=false;
  begin
    perform public.server_tx_mark_task_could_not_do_v1('10600000-0000-0000-0000-000000000001',gen_random_uuid(),v_done_id,false,'pwa');
  exception when others then
    if sqlerrm<>'TASK_TERMINAL' then raise; end if;
    v_failed:=true;
  end;
  if not v_failed then raise exception 'FAIL could-not-do: a completed task must be refused'; end if;
end $$;

reset role;
set role authenticated;
do $$
begin
  perform public.server_tx_mark_task_could_not_do_v1(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),false,'pwa');
  raise exception 'FAIL could-not-do: authenticated must not call the command';
exception when insufficient_privilege then null;
end $$;
reset role;

rollback;

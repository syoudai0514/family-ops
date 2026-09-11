\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  u uuid := gen_random_uuid(); v uuid := gen_random_uuid(); hh uuid; tid uuid; r bigint; result jsonb; op uuid := gen_random_uuid();
begin
  insert into auth.users(id) values(u),(v);
  hh := (public.server_tx_create_household(u,gen_random_uuid(),'Astra duplicate regression','パパ')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role) values(hh,v,'adult');
  tid := (public.server_tx_create_task_with_calendar(u,gen_random_uuid(),'受取に行く','other',current_date,
    time '16:00',time '17:00','special',v,'whole','anytime',null)->>'task_id')::uuid;
  select revision into r from public.task_instances where id=tid;
  result := public.server_tx_commit_concierge_duplicate_update(u,op,'task',tid,r,'受取に行く',current_date+1,null,null);
  if not exists(select 1 from public.task_instances where id=tid and planned_assignee_id=v
    and scheduled_date=current_date+1 and (due_at at time zone 'Asia/Tokyo')::time=time '16:00'
    and (calendar_ends_at at time zone 'Asia/Tokyo')::time=time '17:00'
    and calendar_visibility='special' and revision>r) then
    raise exception 'FAIL partial duplicate update erased owner/deadline/calendar end';
  end if;
  result := public.server_tx_commit_concierge_duplicate_update(u,op,'task',tid,r,'受取に行く',current_date+1,null,null);
  if result->>'receipt'<>'replay' then raise exception 'FAIL response-loss retry did not replay'; end if;
  select revision into r from public.task_instances where id=tid;
  begin
    perform public.server_tx_commit_concierge_duplicate_update(u,gen_random_uuid(),'task',tid,r,'受取に行く',null,null,u);
    raise exception 'FAIL duplicate matching bypassed assignment consent';
  exception when others then
    if sqlerrm<>'ASSIGNMENT_AGREEMENT_REQUIRED' then raise; end if;
  end;
  if (select planned_assignee_id from public.task_instances where id=tid)<>v then
    raise exception 'FAIL assignment changed without agreement';
  end if;
end $$;
rollback;

\set ON_ERROR_STOP on
insert into auth.users(id) values ('3a000000-0000-0000-0000-000000000001'),('3a000000-0000-0000-0000-000000000002');
set role service_role;
do $$
declare a uuid:='3a000000-0000-0000-0000-000000000001'; b uuid:='3a000000-0000-0000-0000-000000000002'; h uuid; r jsonb; task_id uuid; conflict boolean:=false;
begin
  r:=public.server_tx_create_household(a,gen_random_uuid(),'review p1',''); h:=(r->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role) values(h,b,'adult');
  if (select family_role from public.household_members where household_id=h and user_id=a) <> 'papa' or (select family_role from public.household_members where household_id=h and user_id=b) <> 'mama' then raise exception 'FAIL P1-01: adult members need stable P/M backfill'; end if;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by) values(h,'unknown_31','未知','other','anytime','whole',a);
  if (select calendar_visibility from public.task_definitions where household_id=h and code='unknown_31') <> 'hidden' then raise exception 'FAIL P1-12: unknown definition must stay hidden'; end if;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by) values(h,'morning_custom_31','ゴミ出し','household','morning','whole',a);
  if (select task_kind from public.task_definitions where household_id=h and code='morning_custom_31') <> 'morning_chore' then raise exception 'FAIL P1-06: morning chore needs stable kind'; end if;
  r:=public.server_tx_create_task_with_calendar(a,'3a000000-0000-0000-0000-000000000099','皮膚科','medical','2026-09-01','10:00','11:00','special',a,'whole','anytime',null); task_id:=(r->>'task_id')::uuid;
  if (select task_kind from public.task_instances where id=task_id) <> 'special' then raise exception 'FAIL P1-06: explicit calendar task needs special kind'; end if;
  if (public.server_tx_create_task_with_calendar(a,'3a000000-0000-0000-0000-000000000099','皮膚科','medical','2026-09-01','10:00','11:00','special',a,'whole','anytime',null)->>'task_id') <> task_id::text then raise exception 'FAIL P1-14: exact retry must reuse task'; end if;
  begin perform public.server_tx_create_task_with_calendar(a,'3a000000-0000-0000-0000-000000000099','皮膚科','medical','2026-09-01','10:00','11:30','special',a,'whole','anytime',null); exception when others then conflict:=sqlerrm='IDEMPOTENCY_CONFLICT'; end;
  if not conflict then raise exception 'FAIL P1-14: changed end time must conflict'; end if;
end $$;
reset role;
select '31_review_fix_p1_domain: PASS' as result;

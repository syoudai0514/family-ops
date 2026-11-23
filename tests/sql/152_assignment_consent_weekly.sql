\set ON_ERROR_STOP on
begin;
do $$
declare
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); h uuid; h2 uuid; token text;
  def uuid; note uuid; note2 uuid; first_offer uuid; first_items jsonb; r jsonb; i int;
  today date:=(now() at time zone 'Asia/Tokyo')::date;
  sunday date:=today+(7-extract(isodow from today)::integer);
  fake_now timestamptz;
begin
  fake_now:=(sunday::timestamp+time '08:00') at time zone 'Asia/Tokyo';
  insert into auth.users(id) values(a),(b),(outsider);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'weekly consent','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  h2:=(public.server_tx_create_household(outsider,gen_random_uuid(),'other','O')->>'household_id')::uuid;
  for i in 1..4 loop
    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by)
      values(h,'weekly_test_'||i,'予定'||i,'chore','morning','whole',a) returning id into def;
    insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,effective_from,created_by)
      values(h,def,1,'weekly-a','fixed',b,today,a), (h,def,2,'weekly-b','fixed',b,today,a);
  end loop;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,b,'daily_brief.v2','朝のおうちノート','body',jsonb_build_object('brief',jsonb_build_object('local_date',sunday)),gen_random_uuid()::text) returning id into note;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,b,'daily_brief.v2','朝のおうちノート','body',jsonb_build_object('brief',jsonb_build_object('local_date',sunday)),gen_random_uuid()::text) returning id into note2;
  if public.server_tx_prepare_weekly_assignment_consent_v1(b,note,fake_now-interval '1 day')<>'[]'::jsonb then raise exception 'non Sunday proposed'; end if;
  begin perform public.server_tx_prepare_weekly_assignment_consent_v1(outsider,note,fake_now); raise exception 'other household prepared';
    exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  first_items:=public.server_tx_prepare_weekly_assignment_consent_v1(b,note,fake_now);
  if jsonb_array_length(first_items)<>3 then raise exception 'expected maximum 3: %',first_items; end if;
  if (select count(distinct x#>>'{snapshot,definition_id}') from jsonb_array_elements(first_items) x)<>3 then raise exception 'repeated chore'; end if;
  if first_items is distinct from public.server_tx_prepare_weekly_assignment_consent_v1(b,note,fake_now) then raise exception 'retry changed weekly cards'; end if;
  if public.server_tx_prepare_weekly_assignment_consent_v1(b,note2,fake_now)<>'[]'::jsonb then raise exception 'second weekly round'; end if;
  first_offer:=(first_items->0->>'offer_id')::uuid;
  perform public.server_tx_accept_assignment_consent_v1(b,first_offer);
  r:=public.server_tx_prepare_weekly_assignment_consent_v1(b,note,fake_now);
  if jsonb_array_length(r)<>2 then raise exception 'already answered card was resent'; end if;
  if has_function_privilege('authenticated','public.server_tx_prepare_weekly_assignment_consent_v1(uuid,uuid,timestamptz)','execute') then raise exception 'public weekly preparation'; end if;
end $$;
rollback;
select 'assignment_consent_weekly: PASS' as result;

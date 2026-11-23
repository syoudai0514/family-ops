\set ON_ERROR_STOP on
begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid; token text; definition uuid; rule_id uuid; a_ref uuid; template uuid; offer uuid;
  ids uuid[]:='{}'::uuid[]; i int; result jsonb; op uuid:=gen_random_uuid(); today date:=(now() at time zone 'Asia/Tokyo')::date;
begin
  insert into auth.users(id) values(a),(b);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'review','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token'; perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  select id into a_ref from public.domain_actor_refs where household_id=h and real_user_id=a and actor_kind='real_user';
  insert into public.transport_weekly_templates(household_id,valid_from,created_by,created_by_actor_ref_id) values(h,today,a,a_ref) returning id into template;
  insert into public.transport_weekly_template_days(household_id,template_id,weekday,dropoff_user_id) values(h,template,1,b);
  for i in 1..4 loop
    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,task_kind,created_by)
      values(h,'review_'||i,'見直し'||i,'household','morning','whole','morning_chore',a) returning id into definition;
    ids:=array_append(ids,definition);
    insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,effective_from,created_by)
      values(h,definition,1,'review','fixed',b,today-40,a) returning id into rule_id;
    insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,origin,title,category,routine_phase,scheduled_date,
      planned_assignee_id,assignment_mode,completion_mode,status,source,created_by,completed_at,actual_completed_by_id)
      values(h,definition,rule_id,'recurring','見直し'||i,'household','morning',today-7,b,'person','whole',case when i=4 then 'completed' else 'todo' end,'test',a,case when i=4 then now() else null end,case when i=4 then b else null end);
  end loop;
  -- A recently recorded older occurrence also counts as recent activity.
  update public.task_instances set scheduled_date=today-50 where task_definition_id=ids[4];
  insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,ids[4],rule_id,'recurring','未記録の最近分','household','morning',today-7,b,'person','whole','todo','test',a);
  result:=public.server_read_assignment_review_v1(a);
  if jsonb_array_length(result->'routines')<>4 or (select count(*) from jsonb_array_elements(result->'routines') x where (x->>'review_suggested')::boolean)<>3
    or (select count(*) from jsonb_array_elements(result->'routines') x where (x->>'tentative')::boolean)<>4
    or result->>'transport_tentative'<>'true' then raise exception 'bad owner review %',result; end if;
  if public.server_read_assignment_review_v1(b)->'routines'<>'[]'::jsonb then raise exception 'partner saw private suggestions'; end if;
  offer:=(public.server_tx_prepare_assignment_consent_v1(b,'transport',template)->>'offer_id')::uuid;
  perform public.server_tx_accept_assignment_consent_v1(b,offer);
  if public.server_read_assignment_review_v1(a)->>'transport_tentative'<>'false' then raise exception 'agreed transport still tentative'; end if;
  begin perform public.server_tx_review_assignment_v1(b,gen_random_uuid(),ids[1],'stop'); raise exception 'partner modified suggestion';
    exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  result:=public.server_tx_review_assignment_v1(a,op,ids[1],'keep');
  if result->>'ok'<>'true' or private.fn_assignment_review_suggested_v1(h,a,ids[1]) then raise exception 'keep did not snooze'; end if;
  if public.server_tx_review_assignment_v1(a,op,ids[1],'keep') is distinct from result then raise exception 'keep replay'; end if;
  perform public.server_tx_review_assignment_v1(a,gen_random_uuid(),ids[2],'stop');
  if (select is_active from public.task_definitions where id=ids[2]) then raise exception 'stop failed'; end if;
  perform public.server_tx_review_assignment_v1(a,gen_random_uuid(),ids[3],'optional');
  if (select default_expectation from public.task_definitions where id=ids[3])<>'optional' then raise exception 'optional failed'; end if;
  begin perform public.server_tx_review_assignment_v1(a,gen_random_uuid(),ids[4],'keep'); raise exception 'recorded work suggested';
    exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  if has_function_privilege('authenticated','public.server_read_assignment_review_v1(uuid)','execute')
    or has_function_privilege('authenticated','public.server_tx_review_assignment_v1(uuid,uuid,uuid,text)','execute') then raise exception 'public review RPC'; end if;
end $$;
rollback;
select 'assignment_review: PASS' as result;

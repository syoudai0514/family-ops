\set ON_ERROR_STOP on
begin;
do $$
declare
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); h uuid; h2 uuid; token text; a_ref uuid;
  definition uuid; rule_id uuid; own_rule uuid; dyn_rule uuid; task_id uuid; v_template_id uuid; offer_id uuid; other_offer uuid;
  r jsonb; today date:=(now() at time zone 'Asia/Tokyo')::date;
begin
  insert into auth.users(id) values(a),(b),(outsider);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'consent fixture','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  h2:=(public.server_tx_create_household(outsider,gen_random_uuid(),'other','O')->>'household_id')::uuid;
  select id into a_ref from public.domain_actor_refs where household_id=h and real_user_id=a and actor_kind='real_user';
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by)
  values(h,'consent_test','準備','chore','morning','whole',a) returning id into definition;
  insert into public.task_subtask_definitions(household_id,task_definition_id,title,required,sort_order,is_active)
  values(h,definition,'今の準備',true,1,true),(h,definition,'削除済み',true,2,false);
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,effective_from,created_by)
  values(h,definition,1,'other','fixed',b,today,a) returning id into rule_id;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,effective_from,created_by)
  values(h,definition,2,'self','fixed',a,today,a) returning id into own_rule;
  if private.fn_has_assignment_consent_v1(h,b,'rule',rule_id) then raise exception 'other person implicitly agreed'; end if;
  if private.fn_has_assignment_consent_v1(h,a,'rule',own_rule) then raise exception 'historical creator treated as latest editor'; end if;
  if (public.server_tx_prepare_assignment_consent_v1(a,'rule',rule_id)->>'unavailable')<>'true' then raise exception 'wrong person could prepare'; end if;
  r:=public.server_tx_prepare_assignment_consent_v1(b,'rule',rule_id); offer_id:=(r->>'offer_id')::uuid;
  if jsonb_array_length(r#>'{snapshot,subtasks}')<>1 or r::text like '%削除済み%' then raise exception 'inactive subtask shown'; end if;
  if offer_id is null or (public.server_tx_prepare_assignment_consent_v1(b,'rule',rule_id)->>'offer_id')::uuid<>offer_id then raise exception 'preparation is not idempotent'; end if;
  begin perform public.server_tx_accept_assignment_consent_v1(a,offer_id); raise exception 'wrong person accepted';
    exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  begin perform public.server_tx_accept_assignment_consent_v1(outsider,offer_id); raise exception 'outsider accepted';
    exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  r:=public.server_tx_accept_assignment_consent_v1(b,offer_id);
  if r->>'ok'<>'true'
    or not private.fn_has_assignment_consent_v1(h,b,'rule',rule_id) then raise exception 'accept failed'; end if;
  if (public.server_tx_accept_assignment_consent_v1(b,offer_id)->>'already_agreed')<>'true' then raise exception 'duplicate accept'; end if;
  -- Legacy writers can change a rule without incrementing its numeric version.
  update public.recurrence_rules set scheduled_local_time='07:15' where id=rule_id;
  if private.fn_has_assignment_consent_v1(h,b,'rule',rule_id)
    or (public.server_tx_accept_assignment_consent_v1(b,offer_id)->>'stale')<>'true' then raise exception 'changed rule reused consent'; end if;
  other_offer:=(public.server_tx_prepare_assignment_consent_v1(b,'rule',rule_id)->>'offer_id')::uuid;
  update public.task_definitions set title='別の準備' where id=definition;
  if (public.server_tx_accept_assignment_consent_v1(b,other_offer)->>'stale')<>'true' then raise exception 'changed title accepted'; end if;
  other_offer:=(public.server_tx_prepare_assignment_consent_v1(b,'rule',rule_id)->>'offer_id')::uuid;
  r:=public.server_tx_defer_assignment_consent_v1(b,other_offer,'later');
  if r->>'ok'<>'true' or exists(select 1 from public.user_notifications where household_id=h and type='assignment.consent_change_requested')
    or private.fn_has_assignment_consent_v1(h,b,'rule',rule_id) then raise exception 'later changed state or notified'; end if;
  other_offer:=(public.server_tx_prepare_assignment_consent_v1(b,'rule',rule_id)->>'offer_id')::uuid;
  r:=public.server_tx_defer_assignment_consent_v1(b,other_offer,'change');
  if r->>'ok'<>'true' or (select count(*) from public.user_notifications where household_id=h and recipient_user_id=a
      and type='assignment.consent_change_requested' and body='「別の準備」の担当を相談したいそうです。')<>1
    or (select planned_assignee_id from public.recurrence_rules where id=rule_id) is distinct from b
    or private.fn_has_assignment_consent_v1(h,b,'rule',rule_id) then raise exception 'change request modified assignment or did not notify'; end if;
  if (public.server_tx_defer_assignment_consent_v1(b,other_offer,'change')->>'already_answered')<>'true'
    or (select count(*) from public.user_notifications where household_id=h and type='assignment.consent_change_requested')<>1 then raise exception 'change request was sent twice'; end if;
  other_offer:=(public.server_tx_prepare_assignment_consent_v1(a,'rule',own_rule)->>'offer_id')::uuid;
  r:=public.server_tx_defer_assignment_consent_v1(a,other_offer,'change');
  if r->>'ok'<>'true' or (select count(*) from public.user_notifications where household_id=h and recipient_user_id=b
      and type='assignment.consent_change_requested')<>1 then raise exception 'consultation sent to old creator instead of other adult'; end if;
  -- Role-dependent rules require an actual upcoming assignment to this person.
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,effective_from,created_by)
  values(h,definition,3,'dynamic','dropoff_assignee',today,a) returning id into dyn_rule;
  if (public.server_tx_prepare_assignment_consent_v1(b,'rule',dyn_rule)->>'unavailable')<>'true' then raise exception 'unassigned dynamic offer'; end if;
  insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
  values(h,definition,dyn_rule,'recurring','別の準備','chore','morning',today,b,'person','whole','todo','test',a) returning id into task_id;
  if private.fn_task_assignment_consent_v1(h,b,task_id) or private.fn_task_assignment_consent_v1(h,a,task_id) then
    raise exception 'unagreed task was allowed'; end if;
  other_offer:=(public.server_tx_prepare_assignment_consent_v1(b,'rule',dyn_rule)->>'offer_id')::uuid;
  r:=public.server_tx_accept_assignment_consent_v1(b,other_offer);
  if other_offer is null or r->>'ok'<>'true'
    or not private.fn_has_assignment_consent_v1(h,b,'rule',dyn_rule)
    or not private.fn_task_assignment_consent_v1(h,b,task_id)
    or private.fn_has_assignment_consent_v1(h,a,'rule',dyn_rule) then raise exception 'dynamic recipient consent incorrect'; end if;
  update public.recurrence_rules set scheduled_local_time='09:00' where id=dyn_rule;
  if private.fn_task_assignment_consent_v1(h,b,task_id) then raise exception 'changed rule allowed task'; end if;
  update public.task_instances set assignment_source='agreement' where id=task_id;
  if not private.fn_task_assignment_consent_v1(h,b,task_id) then raise exception 'accepted one-off handoff was hidden'; end if;
  insert into public.transport_weekly_templates(household_id,valid_from,created_by,created_by_actor_ref_id)
    values(h,today,a,a_ref) returning id into v_template_id;
  insert into public.transport_weekly_template_days(household_id,template_id,weekday,dropoff_user_id,pickup_user_id,dropoff_local_time)
    values(h,v_template_id,1,b,a,'08:00');
  other_offer:=(public.server_tx_prepare_assignment_consent_v1(b,'transport',v_template_id)->>'offer_id')::uuid;
  r:=public.server_tx_accept_assignment_consent_v1(b,other_offer);
  if other_offer is null or r->>'ok'<>'true'
    or not private.fn_has_assignment_consent_v1(h,b,'transport',v_template_id)
    or private.fn_has_assignment_consent_v1(h,a,'transport',v_template_id) then raise exception 'transport recipient consent incorrect'; end if;
  update public.transport_weekly_template_days set dropoff_local_time='08:30' where transport_weekly_template_days.template_id=v_template_id and weekday=1;
  if private.fn_has_assignment_consent_v1(h,b,'transport',v_template_id) then raise exception 'changed transport reused consent'; end if;
  if private.fn_line_preference_column_for_type('assignment.consent_change_requested') is distinct from 'request_line'
    or private.fn_line_preference_column_for_type('thanks') is distinct from 'request_line' then raise exception 'notification preference mapping lost'; end if;
  if has_function_privilege('authenticated','public.server_tx_prepare_assignment_consent_v1(uuid,text,uuid)','execute')
    or has_function_privilege('authenticated','public.server_tx_accept_assignment_consent_v1(uuid,uuid)','execute')
    or has_function_privilege('authenticated','public.server_tx_defer_assignment_consent_v1(uuid,uuid,text)','execute') then raise exception 'public consent RPC'; end if;
end $$;
rollback;
select 'assignment_consent_foundation: PASS' as result;

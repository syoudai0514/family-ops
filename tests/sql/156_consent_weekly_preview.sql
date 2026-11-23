\set ON_ERROR_STOP on
begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid; token text; a_ref uuid; template uuid; def uuid; rule_id uuid;
  special_def uuid; special_rule uuid; day date:=(now() at time zone 'Asia/Tokyo')::date+1; offer uuid; preview text;
begin
  insert into auth.users(id) values(a),(b);
  insert into public.profiles(user_id,display_name) values(a,'Papa'),(b,'Mama');
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'weekly privacy','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token'; perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  select id into a_ref from public.domain_actor_refs where household_id=h and real_user_id=a and actor_kind='real_user';
  insert into public.transport_weekly_templates(household_id,valid_from,created_by,created_by_actor_ref_id) values(h,day,a,a_ref) returning id into template;
  insert into public.transport_weekly_template_days(household_id,template_id,weekday,dropoff_user_id,dropoff_local_time)
    values(h,template,extract(isodow from day)::int,b,'08:00');
  select id into def from public.task_definitions where household_id=h and code='dropoff';
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,effective_from,created_by,transport_template_id,transport_leg)
    values(h,def,extract(isodow from day)::int,'privacy-test','fixed',b,day,a,template,'dropoff') returning id into rule_id;
  insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,def,rule_id,'recurring','送り','transport','morning',day,b,'person','whole','todo','test',a);
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by)
    values(h,'private_special','仮の特別作業','chore','morning','whole',a) returning id into special_def;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,effective_from,created_by)
    values(h,special_def,extract(isodow from day)::int,'privacy-test','fixed',b,day,a) returning id into special_rule;
  insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,special_def,special_rule,'recurring','仮の特別作業','chore','morning',day,b,'person','whole','todo','test',a,'special');
  preview:=private.fn_render_weekly_preview_for_recipient_v1(h,day,b);
  if preview not like '%送り 相談中%' or preview like '%送り B%' or preview like '%仮の特別作業%' then raise exception 'tentative leaked: %',preview; end if;
  preview:=private.fn_render_weekly_preview_for_recipient_v1(h,day,a);
  if preview not like '%送り B%' then raise exception 'planner lost useful preview: %',preview; end if;
  offer:=(public.server_tx_prepare_assignment_consent_v1(b,'transport',template)->>'offer_id')::uuid;
  perform public.server_tx_accept_assignment_consent_v1(b,offer);
  preview:=private.fn_render_weekly_preview_for_recipient_v1(h,day,b);
  if preview not like '%送り B%' then raise exception 'agreed transport hidden: %',preview; end if;
end $$;
rollback;
select 'consent_weekly_preview: PASS' as result;

\set ON_ERROR_STOP on
begin;
do $$
declare
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  h uuid; h2 uuid; token text; definition uuid; rule_id uuid; recurring uuid; manual uuid; offer uuid;
  item jsonb; items jsonb; day date:=(now() at time zone 'Asia/Tokyo')::date;
begin
  insert into auth.users(id) values(a),(b),(outsider);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'transport display','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  h2:=(public.server_tx_create_household(outsider,gen_random_uuid(),'other','O')->>'household_id')::uuid;
  select id into definition from public.task_definitions where household_id=h and code='pickup';
  if definition is null then
    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by)
    values(h,'pickup','お迎え','pickup','evening','whole',a) returning id into definition;
  end if;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,effective_from,created_by)
    values(h,definition,extract(isodow from day)::int,'consent-display','fixed',b,day,a) returning id into rule_id;
  insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,definition,rule_id,'recurring','仮のお迎え','pickup','evening',day,b,'person','whole','todo','test',a) returning id into recurring;
  manual:=(public.server_tx_create_task(a,gen_random_uuid(),'今日だけのお迎え','pickup',day,null,b,'whole','evening',null)->>'task_id')::uuid;
  items:=public.server_read_line_tasks_display(a,day);
  select value into item from jsonb_array_elements(items) where value->>'task_id'=recurring::text;
  if item->>'task_code'<>'pickup' or (item->>'assignment_confirmed')::boolean is distinct from false then
    raise exception 'tentative assignment incorrectly agreed: %',item; end if;
  select value into item from jsonb_array_elements(items) where value->>'task_id'=manual::text;
  if (item->>'assignment_confirmed')::boolean is distinct from true then raise exception 'one-off assignment disappeared: %',item; end if;
  offer:=(public.server_tx_prepare_assignment_consent_v1(b,'rule',rule_id)->>'offer_id')::uuid;
  perform public.server_tx_accept_assignment_consent_v1(b,offer);
  items:=public.server_read_line_tasks_display(a,day);
  select value into item from jsonb_array_elements(items) where value->>'task_id'=recurring::text;
  if (item->>'assignment_confirmed')::boolean is distinct from true then raise exception 'confirmed assignment hidden: %',item; end if;
  items:=public.server_read_line_tasks_display(outsider,day);
  if items::text like '%仮のお迎え%' or items::text like '%今日だけのお迎え%' then raise exception 'cross-household task exposed'; end if;
  if has_function_privilege('authenticated','public.server_read_line_tasks_display(uuid,date)','execute')
    or not has_function_privilege('service_role','public.server_read_line_tasks_display(uuid,date)','execute') then
    raise exception 'reader grants changed'; end if;
end $$;
rollback;
select 'line_transport_consent_display: PASS' as result;

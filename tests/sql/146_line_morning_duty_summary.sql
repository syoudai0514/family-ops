\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  actor uuid:=gen_random_uuid(); partner uuid:=gen_random_uuid(); h uuid; token text;
  def uuid; codmon_def uuid; rule_id uuid; codmon_rule uuid; day date:='2027-02-02';
  source jsonb; result jsonb; body text; interactive text;
begin
  insert into auth.users(id) values(actor),(partner);
  h:=(public.server_tx_create_household(actor,gen_random_uuid(),'Duty','パパ')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(actor,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(partner,gen_random_uuid(),token,'ママ');
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by)
    values(h,'duty_test','朝の当番','household','morning','whole',actor) returning id into def;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by)
    values(h,'codmon_submit','コドモン送信','nursery','morning','whole',actor) returning id into codmon_def;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,assignee_strategy,effective_from,created_by)
    values(h,def,2,'dropoff_assignee',day,actor) returning id into rule_id;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,assignee_strategy,effective_from,created_by)
    values(h,codmon_def,2,'dropoff_assignee',day,actor) returning id into codmon_rule;
  insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,origin,title,category,routine_phase,scheduled_date,completion_mode,status,source,created_by,planned_assignee_id,assignment_mode,expectation,due_at)
  values
    (h,def,rule_id,'recurring','朝食','household','morning',day,'whole','todo','test',actor,actor,'person','normal',timestamptz '2027-02-02 07:00+09'),
    (h,def,rule_id,'recurring','着替え','household','morning',day,'whole','todo','test',actor,actor,'person','normal',timestamptz '2027-02-02 07:20+09'),
    (h,codmon_def,codmon_rule,'recurring','コドモン送信','nursery','morning',day,'whole','todo','test',actor,actor,'person','normal',timestamptz '2027-02-02 09:15+09'),
    (h,def,null,'manual','ゴミ出し','household','morning',day,'whole','todo','test',actor,actor,'person','normal',timestamptz '2027-02-02 07:30+09'),
    (h,def,rule_id,'recurring','共有作業','household','morning',day,'whole','todo','test',actor,null,'anyone','normal',timestamptz '2027-02-02 07:40+09'),
    (h,def,rule_id,'recurring','任意作業','household','morning',day,'whole','todo','test',actor,actor,'person','optional',timestamptz '2027-02-02 07:50+09'),
    (h,def,rule_id,'recurring','別担当','household','morning',day,'whole','todo','test',actor,partner,'person','normal',timestamptz '2027-02-02 08:00+09'),
    (h,def,rule_id,'recurring','翌日の作業','household','morning',day+1,'whole','todo','test',actor,actor,'person','normal',timestamptz '2027-02-03 08:10+09');
  select jsonb_build_object('display_recipient_user_id',actor,'own_task_groups',jsonb_build_object(
    'morning',jsonb_agg(jsonb_build_object('task_id',t.id,'title',t.title,'display_title',t.title,
      'due_at',t.due_at,'assignment_mode',t.assignment_mode,'expectation',t.expectation) order by t.due_at),
    'daytime','[]'::jsonb,'evening','[]'::jsonb,'optional','[]'::jsonb))
    into source from public.task_instances t where t.household_id=h and t.source='test';
  -- Isolate duty grouping; the consent wrapper is exercised separately.
  result:=private.fn_daily_brief_before_consent_v1(source,actor,timestamptz '2027-02-02 06:30+09','morning');
  body:=private.fn_render_daily_brief_text_v4(result,'morning_focus');
  if body not like '%朝の当番（3件）%' or body not like '%07:00 朝の当番%' or body not like '%09:15 コドモン送信%' then
    raise exception 'missing summary, endpoint, or codmon deadline: %',body;
  end if;
  if body like '%着替え%' or body not like '%ゴミ出し%' or body not like '%共有作業%' or body not like '%任意作業%' or body not like '%別担当%' or body not like '%翌日の作業%' then
    raise exception 'ordinary tasks changed or middle duty remained: %',body;
  end if;
  interactive:=private.fn_render_daily_brief_text_v4(source,'morning');
  if interactive not like '%着替え%' or interactive like '%朝の当番（3件）%' then raise exception 'interactive list changed: %',interactive; end if;
  result:=private.fn_daily_brief_before_consent_v1(source,actor,timestamptz '2027-02-02 20:00+09','evening');
  if result::text like '%朝の当番（3件）%' then raise exception 'evening brief unexpectedly grouped'; end if;
end $$;
rollback;
select 'line_morning_duty_summary: PASS' as result;

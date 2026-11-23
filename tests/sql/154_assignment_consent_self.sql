\set ON_ERROR_STOP on
begin;
do $$
declare
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid; token text; definition uuid; own_rule uuid; other_rule uuid; legacy_rule uuid;
  task_id uuid; template uuid; op uuid:=gen_random_uuid(); transport_op uuid:=gen_random_uuid(); r jsonb; days jsonb;
  today date:=(now() at time zone 'Asia/Tokyo')::date;
begin
  insert into auth.users(id) values(a),(b);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'self consent','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by)
    values(h,'self_consent','自分の用事','chore','morning','whole',a) returning id into definition;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,effective_from,created_by)
    values(h,definition,1,'old-self','fixed',a,today,a) returning id into legacy_rule;
  r:=public.server_tx_change_recurrence(a,op,definition,extract(isodow from today)::int,'self','fixed',a,'08:00',60,today);
  own_rule:=(r->>'rule_id')::uuid;
  if not private.fn_has_assignment_consent_v1(h,a,'rule',own_rule) then raise exception 'self-authored rule was not agreed'; end if;
  if private.fn_has_assignment_consent_v1(h,a,'rule',legacy_rule) then raise exception 'new save silently accepted a historical rule'; end if;
  select id into task_id from public.task_instances where household_id=h and recurrence_rule_id=own_rule and scheduled_date>=today order by scheduled_date limit 1;
  if task_id is null or not private.fn_task_assignment_consent_v1(h,a,task_id) then raise exception 'self-created task hidden'; end if;
  r:=public.server_tx_change_recurrence(a,gen_random_uuid(),definition,extract(isodow from today)::int,'other','fixed',b,'08:30',60,today);
  other_rule:=(r->>'rule_id')::uuid;
  if private.fn_has_assignment_consent_v1(h,b,'rule',other_rule) then raise exception 'other person silently agreed'; end if;
  update public.task_definitions set title='変わった用事' where id=definition;
  if private.fn_has_assignment_consent_v1(h,a,'rule',own_rule) then raise exception 'changed content stayed agreed'; end if;
  perform public.server_tx_change_recurrence(a,op,definition,extract(isodow from today)::int,'self','fixed',a,'08:00',60,today);
  if private.fn_has_assignment_consent_v1(h,a,'rule',own_rule) then raise exception 'replayed old save accepted changed content'; end if;
  select jsonb_agg(jsonb_build_object('weekday',n,'dropoff_user_id',a,'pickup_user_id',b,
    'dropoff_local_time','08:00','pickup_local_time','17:00') order by n) into days from generate_series(1,7) n;
  r:=public.server_tx_save_transport_template_v2(a,transport_op,today,days); template:=(r->>'template_id')::uuid;
  if not private.fn_has_assignment_consent_v1(h,a,'transport',template)
    or private.fn_has_assignment_consent_v1(h,b,'transport',template) then raise exception 'transport self consent leaked to partner'; end if;
  update public.transport_weekly_template_days set dropoff_local_time='09:00' where transport_weekly_template_days.template_id=template and weekday=1;
  if private.fn_has_assignment_consent_v1(h,a,'transport',template) then raise exception 'changed transport stayed agreed'; end if;
  begin perform public.server_tx_save_transport_template_v2(a,transport_op,today,days);
    exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if; end;
  if private.fn_has_assignment_consent_v1(h,a,'transport',template) then raise exception 'replayed old template save accepted changed content'; end if;
end $$;
rollback;
select 'assignment_consent_self: PASS' as result;

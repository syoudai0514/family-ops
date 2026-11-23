\set ON_ERROR_STOP on
begin;
do $$
declare
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid; token text; d uuid; rule_id uuid; recurring uuid; manual uuid;
  note uuid; note2 uuid; offer uuid; prior_batch uuid; batch uuid; r jsonb; brief jsonb; filtered jsonb;
  today date:=(now() at time zone 'Asia/Tokyo')::date; workday date:=(now() at time zone 'Asia/Tokyo')::date+1;
  work_time timestamptz;
begin
  update public.households set morning_nudge_local_time=null;
  insert into auth.users(id) values(a),(b);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'consent integration','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  update public.notification_preferences set quiet_mode='normal' where household_id=h;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by)
    values(h,'consent_integrated','朝の準備','chore','morning','whole',a) returning id into d;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,effective_from,created_by)
    values(h,d,1,'morning','fixed',b,today,a) returning id into rule_id;
  insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,d,rule_id,'recurring','仮の朝支度','chore','morning',today,b,'person','whole','todo','test',a) returning id into recurring;
  manual:=(public.server_tx_create_task(b,gen_random_uuid(),'自分の予定','chore',today,null,b,'whole','morning','[]'::jsonb)->>'task_id')::uuid;
  select jsonb_build_object('display_recipient_user_id',b,'local_date',today,
    'own_task_groups',jsonb_build_object('morning',jsonb_agg(jsonb_build_object('task_id',id,'title',title,'display_title',title,
      'revision',revision,'status',status,'expectation',expectation,'assignment_mode',assignment_mode,'planned_assignee_id',planned_assignee_id) order by id),
      'daytime','[]'::jsonb,'evening','[]'::jsonb,'optional','[]'::jsonb),
    'exceptions',jsonb_build_array(jsonb_build_object('task_id',recurring,'title','仮の朝支度')),
    'nested',jsonb_build_object('items',jsonb_build_array(jsonb_build_object('task_id',recurring,'title','仮の朝支度'))))
    into brief from public.task_instances where id in (recurring,manual);
  filtered:=private.fn_daily_brief_for_line_v1(brief,b,now(),'morning');
  if filtered::text like '%仮の朝支度%' or filtered::text not like '%自分の予定%' then raise exception 'unagreed task still in note or manual task lost: %',filtered; end if;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,b,'daily_brief.v2','朝のおうちノート','body',jsonb_build_object('brief',brief),'consent-bulk-1') returning id into note;
  r:=public.server_tx_prepare_line_bulk_v1(b,note); batch:=(r->>'id')::uuid;
  if batch is null or (select jsonb_array_length(items) from private.line_bulk_batches where id=batch)<>1
    or (select items::text like '%'||recurring::text||'%' from private.line_bulk_batches where id=batch) then raise exception 'tentative task included in bulk'; end if;
  -- A button prepared before rollout is checked again when tapped.
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,b,'daily_brief.v2','朝のおうちノート','body',jsonb_build_object('brief',brief),'consent-bulk-old') returning id into note2;
  r:=public.server_tx_prepare_line_bulk_before_consent_v1(b,note2); prior_batch:=(r->>'id')::uuid;
  begin perform public.server_tx_complete_line_bulk_v1(b,prior_batch); raise exception 'old button completed tentative work';
    exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  if (select status from public.task_instances where id=manual)<>'todo' then raise exception 'stale old batch partly completed'; end if;
  offer:=(public.server_tx_prepare_assignment_consent_v1(b,'rule',rule_id)->>'offer_id')::uuid;
  perform public.server_tx_accept_assignment_consent_v1(b,offer);
  filtered:=private.fn_daily_brief_for_line_v1(brief,b,now(),'morning');
  if filtered::text not like '%仮の朝支度%' then raise exception 'agreed task hidden'; end if;
  -- A rule change after the button was sent makes the old batch unsafe.
  update public.recurrence_rules set scheduled_local_time='08:00' where id=rule_id;
  begin perform public.server_tx_complete_line_bulk_v1(b,prior_batch); raise exception 'changed consent completed';
    exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  -- On a workday a tentative recurring task alone never creates a nudge;
  -- accepting its current contents makes the nudge appear.
  while private.is_jp_nonworkday(workday) loop workday:=workday+1; end loop;
  work_time:=(workday::timestamp+time '07:30') at time zone 'Asia/Tokyo';
  update public.task_instances set status='cancelled' where id=manual;
  update public.task_instances set scheduled_date=workday,due_at=(workday::timestamp+time '08:00') at time zone 'Asia/Tokyo' where id=recurring;
  if public.server_tx_dispatch_morning_nudges(work_time)<>0 then raise exception 'tentative task generated nudge'; end if;
  offer:=(public.server_tx_prepare_assignment_consent_v1(b,'rule',rule_id)->>'offer_id')::uuid;
  perform public.server_tx_accept_assignment_consent_v1(b,offer);
  if public.server_tx_dispatch_morning_nudges(work_time)<>1 then raise exception 'agreed task did not generate nudge'; end if;
  if (select body from public.user_notifications where household_id=h and recipient_user_id=b and type='morning_nudge') not like '%仮の朝支度%' then raise exception 'agreed task missing from nudge'; end if;
end $$;
rollback;
select 'assignment_consent_integration: PASS' as result;

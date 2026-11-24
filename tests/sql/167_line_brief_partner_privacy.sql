\set ON_ERROR_STOP on
begin;
do $$
declare
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  h uuid; h2 uuid; token text; definition uuid; rule_id uuid; pickup uuid; foreign_task uuid; offer uuid; note uuid;
  day date:=(now() at time zone 'Asia/Tokyo')::date; brief jsonb; prepared jsonb; body text; mode text;
begin
  insert into auth.users(id) values(a),(b),(outsider);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'brief privacy','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  update public.household_members set family_role=case user_id when a then 'papa' else 'mama' end where household_id=h;
  h2:=(public.server_tx_create_household(outsider,gen_random_uuid(),'other','O')->>'household_id')::uuid;
  select id into definition from public.task_definitions where household_id=h and code='pickup';
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,effective_from,created_by)
    values(h,definition,extract(isodow from day)::int,'brief-privacy','fixed',b,day,a) returning id into rule_id;
  insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,definition,rule_id,'recurring','園のお迎え','pickup','evening',day,b,'person','whole','todo','test',a) returning id into pickup;
  foreign_task:=(public.server_tx_create_task(outsider,gen_random_uuid(),'別世帯の迎え','pickup',day,null,outsider,'whole','evening',null)->>'task_id')::uuid;
  brief:=jsonb_build_object('display_recipient_user_id',a,'own_task_groups',jsonb_build_object(
    'morning',jsonb_build_array(jsonb_build_object('title','自分の朝作業')),
    'daytime','[]'::jsonb,'evening',jsonb_build_array(jsonb_build_object('title','自分の夜作業')),'optional','[]'::jsonb),
    'schedule',jsonb_build_array(jsonb_build_object('title','家族の予定')),
    'partner_summary',jsonb_build_object('critical_items',jsonb_build_array(
      jsonb_build_object('task_id',pickup,'title','園のお迎え','task_kind','transport'),
      jsonb_build_object('title','相手の個人的な作業','task_kind','evening_chore'))));
  foreach mode in array array['morning_focus','morning','daytime','evening'] loop
    prepared:=private.fn_daily_brief_for_line_v1(brief,a,now(),case when mode='morning_focus' then 'morning' else mode end);
    body:=private.fn_render_daily_brief_text_v4(prepared,mode);
    if body like '%相手の個人的な作業%' or body like '%相手の担当で確認したいこと%'
      or body not like '%家族の共有事項%園のお迎え（担当は未確認）%' or body not like '%家族の予定%' then
      raise exception 'unsafe or incomplete % note: %',mode,body; end if;
    if mode='evening' and (body like '%自分の朝作業%' or body not like '%自分の夜作業%') then
      raise exception 'evening carryover changed: %',body; end if;
  end loop;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,a,'daily_brief.v2','朝のおうちノート','古い相手の日課一覧',
      jsonb_build_object('brief',brief||jsonb_build_object('local_date',day)),'partner-privacy-old-note') returning id into note;
  body:=private.fn_consent_safe_daily_text_v1(h,a,note);
  if body is null or body like '%相手の個人的な作業%' or body like '%古い相手の日課一覧%'
    or body not like '%園のお迎え（担当は未確認）%' or body not like '%家族の予定%' then
    raise exception 'queued old note was not safely rebuilt: %',body; end if;
  offer:=(public.server_tx_prepare_assignment_consent_v1(b,'rule',rule_id)->>'offer_id')::uuid;
  perform public.server_tx_accept_assignment_consent_v1(b,offer);
  body:=private.fn_consent_safe_daily_text_v1(h,a,note);
  if body not like '%園のお迎え（担当: ママ）%' then raise exception 'queued note did not recheck consent: %',body; end if;
  prepared:=private.fn_daily_brief_for_line_v1(brief,a,now(),'morning');
  body:=private.fn_render_daily_brief_text_v4(prepared,'morning');
  if body not like '%園のお迎え（担当: ママ）%' then raise exception 'confirmed transport hidden: %',body; end if;
  -- A queued older payload can omit type metadata; recover it only from the live task.
  brief:=jsonb_set(brief,'{partner_summary,critical_items,0}',(brief#>'{partner_summary,critical_items,0}')-'task_kind');
  prepared:=private.fn_daily_brief_for_line_v1(brief,a,now(),'morning');
  body:=private.fn_render_daily_brief_text_v4(prepared,'morning');
  if body not like '%園のお迎え（担当: ママ）%' then raise exception 'old queued transport hidden: %',body; end if;
  -- A stale or cross-household task reference cannot borrow an assignee label.
  brief:=jsonb_set(brief,'{partner_summary,critical_items,0}',
    (brief#>'{partner_summary,critical_items,0}')||jsonb_build_object('task_id',foreign_task,'task_kind','transport'));
  prepared:=private.fn_daily_brief_for_line_v1(brief,a,now(),'morning');
  body:=private.fn_render_daily_brief_text_v4(prepared,'morning');
  if body not like '%園のお迎え（担当は未確認）%' or body like '%園のお迎え（担当: %' then
    raise exception 'foreign task influenced assignment display: %',body; end if;
  if has_function_privilege('authenticated','private.fn_daily_brief_for_line_v1(jsonb,uuid,timestamptz,text)','execute')
    or not has_function_privilege('service_role','private.fn_daily_brief_for_line_v1(jsonb,uuid,timestamptz,text)','execute') then
    raise exception 'formatter privileges changed'; end if;
end $$;
rollback;
select 'line_brief_partner_privacy: PASS' as result;

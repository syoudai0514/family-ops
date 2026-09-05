-- Q94/Q95: later notice is a visible diff candidate; only human confirmation
-- updates the exact prior schedule/preparation rule. Old confirmed evidence and
-- old preparation rule remain as history; no duplicate event is created.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  u uuid := '68000000-0000-0000-0000-000000000001';
  h uuid; a uuid; child uuid; ctx uuid;
  e1 jsonb; e2 jsonb; i1 uuid; i2 uuid; r bigint;
  d1 jsonb; d2 jsonb; doc1 uuid; doc2 uuid; ext1 uuid; ext2 uuid;
  f1 jsonb; f2 jsonb; event_item1 uuid; prep_item1 uuid; event_item2 uuid; prep_item2 uuid;
  c1 uuid; c2 uuid; event_id uuid; prep_rule1 uuid; prep_rule2 uuid;
begin
  insert into auth.users(id) values(u) on conflict do nothing;
  insert into public.profiles(user_id,display_name) values(u,'Nursery Diff') on conflict do nothing;
  h := (public.server_tx_create_household(u,'68000000-0000-0000-0000-000000000101','Nursery Diff H','Nursery Diff')->>'household_id')::uuid;
  select id into a from public.domain_actor_refs where household_id=h and actor_kind='real_user' and real_user_id=u;
  insert into private.line_user_links(household_id,user_id,line_user_id,status) values(h,u,'LINE-NURSERY-DIFF','active');
  insert into public.family_children(household_id,display_name) values(h,'対象児') returning id into child;
  insert into public.child_school_contexts(household_id,child_id,school_display_name,class_display_name,effective_from,recognition_aliases)
    values(h,child,'ひかり園','そら組','2026-04-01',array['そら組']) returning id into ctx;

  -- First notice and human confirmation.
  e1 := public.server_tx_enqueue_nursery_line_image('evt-diff-1','msg-diff-1','LINE-NURSERY-DIFF',now());
  i1 := (e1->>'intake_id')::uuid;
  perform public.server_tx_claim_nursery_line_images(1,'diff-worker-1');
  select revision into r from private.nursery_line_image_intakes where id=i1;
  d1 := private.fn_command_create_nursery_intake_v1(h,u,a,null,'68000000-0000-0000-0000-000000000201','codmon_notice','nursery-source/diff-1.jpg',now(),'diff-v1','{}','line');
  doc1 := (d1->>'source_document_id')::uuid; ext1 := (d1->>'extraction_id')::uuid;
  f1 := public.server_tx_finish_nursery_image_review(i1,r,'review_ready',doc1,ext1,ctx,'high','{}',jsonb_build_array(
    jsonb_build_object('candidate_key','event','origin','source_explicit','item_kind','timetable','classification','recommended','source_page',1,'confidence_band','high','proposed_value',jsonb_build_object('title','遠足','date','2026-10-08','location','中央公園')),
    jsonb_build_object('candidate_key','prep','origin','source_explicit','item_kind','preparation','source_page',1,'confidence_band','high','proposed_value',jsonb_build_object('trigger_spec',jsonb_build_object('event','遠足'),'preparation_template',jsonb_build_object('items',jsonb_build_array('水筒')),'effective_from','2026-10-01'))
  ),false);
  r := (f1->>'revision')::bigint;
  select id into event_item1 from private.nursery_review_items where intake_id=i1 and candidate_key='event';
  select id into prep_item1 from private.nursery_review_items where intake_id=i1 and candidate_key='prep';
  perform public.server_tx_confirm_nursery_review(u,'68000000-0000-0000-0000-000000000301',i1,r,jsonb_build_array(jsonb_build_object('review_item_id',event_item1),jsonb_build_object('review_item_id',prep_item1)));
  select id,created_family_event_id into c1,event_id from public.nursery_confirmed_items where intake_id=i1 and item_kind='timetable';
  select created_preparation_rule_id into prep_rule1 from public.nursery_confirmed_items where intake_id=i1 and item_kind='preparation';
  if event_id is null or prep_rule1 is null then raise exception 'FAIL Q94 initial canonical targets missing'; end if;

  -- Later notice: insertion of the review candidates must link the previous
  -- human-confirmed rows, but MUST NOT modify them before confirmation.
  e2 := public.server_tx_enqueue_nursery_line_image('evt-diff-2','msg-diff-2','LINE-NURSERY-DIFF',now()+interval '1 day');
  i2 := (e2->>'intake_id')::uuid;
  perform public.server_tx_claim_nursery_line_images(1,'diff-worker-2');
  select revision into r from private.nursery_line_image_intakes where id=i2;
  d2 := private.fn_command_create_nursery_intake_v1(h,u,a,null,'68000000-0000-0000-0000-000000000202','codmon_notice','nursery-source/diff-2.jpg',now()+interval '1 day','diff-v1','{}','line');
  doc2 := (d2->>'source_document_id')::uuid; ext2 := (d2->>'extraction_id')::uuid;
  f2 := public.server_tx_finish_nursery_image_review(i2,r,'review_ready',doc2,ext2,ctx,'high','{}',jsonb_build_array(
    jsonb_build_object('candidate_key','event','origin','source_explicit','item_kind','timetable','classification','recommended','source_page',1,'confidence_band','high','proposed_value',jsonb_build_object('title','遠足（変更）','date','2026-10-09','location','西公園')),
    jsonb_build_object('candidate_key','prep','origin','source_explicit','item_kind','preparation','source_page',1,'confidence_band','high','proposed_value',jsonb_build_object('trigger_spec',jsonb_build_object('event','遠足'),'preparation_template',jsonb_build_object('items',jsonb_build_array('水筒','帽子')),'effective_from','2026-10-02'))
  ),false);
  r := (f2->>'revision')::bigint;
  select id into event_item2 from private.nursery_review_items where intake_id=i2 and candidate_key='event';
  select id into prep_item2 from private.nursery_review_items where intake_id=i2 and candidate_key='prep';
  if not exists(select 1 from private.nursery_review_items where id=event_item2 and previous_confirmed_item_id=c1) then
    raise exception 'FAIL Q95 event diff not linked to previous confirmation';
  end if;
  if not exists(select 1 from private.nursery_review_items rj join public.nursery_confirmed_items ci on ci.id=rj.previous_confirmed_item_id where rj.id=prep_item2 and ci.created_preparation_rule_id=prep_rule1) then
    raise exception 'FAIL Q95 preparation diff not linked to previous confirmation';
  end if;
  if not exists(select 1 from public.family_events where id=event_id and title='遠足' and starts_on='2026-10-08') then
    raise exception 'FAIL Q95 candidate silently modified human-confirmed event';
  end if;
  if not exists(select 1 from public.school_preparation_rules where id=prep_rule1 and active) then
    raise exception 'FAIL Q95 candidate silently modified human-confirmed prep rule';
  end if;

  -- Human confirms the displayed diff. Exact event is updated under lock;
  -- exact prior prep rule is retired and a new active rule is recorded.
  perform public.server_tx_confirm_nursery_review(u,'68000000-0000-0000-0000-000000000302',i2,r,jsonb_build_array(jsonb_build_object('review_item_id',event_item2),jsonb_build_object('review_item_id',prep_item2)));
  if (select count(*) from public.family_events where household_id=h)<>1 then
    raise exception 'FAIL Q94 later schedule confirmation created duplicate event';
  end if;
  if not exists(select 1 from public.family_events where id=event_id and title='遠足（変更）' and starts_on='2026-10-09' and location_text='西公園') then
    raise exception 'FAIL Q94 existing event not updated after human confirmation';
  end if;
  select id,created_preparation_rule_id into c2,prep_rule2 from public.nursery_confirmed_items where intake_id=i2 and item_kind='preparation';
  if prep_rule2 is null or prep_rule2=prep_rule1 then raise exception 'FAIL Q94 new preparation rule missing'; end if;
  if not exists(select 1 from public.school_preparation_rules where id=prep_rule1 and not active) then
    raise exception 'FAIL Q94 prior prep rule not preserved as inactive history';
  end if;
  if not exists(select 1 from public.school_preparation_rules where id=prep_rule2 and active and preparation_template @> '{"items":["帽子"]}'::jsonb) then
    raise exception 'FAIL Q94 new prep rule not active';
  end if;
  if not exists(select 1 from public.nursery_confirmed_items where intake_id=i2 and item_kind='timetable' and created_family_event_id=event_id and supersedes_confirmed_item_id=c1) then
    raise exception 'FAIL Q95 event supersession provenance missing';
  end if;
  if not exists(select 1 from public.nursery_confirmed_items where id=c2 and supersedes_confirmed_item_id is not null) then
    raise exception 'FAIL Q95 prep supersession provenance missing';
  end if;
end;
$$;
reset role;
select '68_nursery_q94_q95_confirmed_diff_apply: PASS' as result;

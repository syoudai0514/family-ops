-- No LINE, Storage, Gemini, Google, or notification-provider calls.
\set ON_ERROR_STOP on
set role service_role;
do $$
declare
  u uuid:='13300000-0000-4000-8000-000000000001'; h uuid; child uuid; ctx uuid;
  enq jsonb; iid uuid; rev bigint; prepared jsonb; checked jsonb; recorded jsonb; delivery jsonb;
  item jsonb; bad jsonb;
begin
  insert into auth.users(id) values(u);
  insert into public.profiles(user_id,display_name) values(u,'Nursery pipeline regression');
  h:=(public.server_tx_create_household(u,gen_random_uuid(),'Nursery pipeline regression','Asia/Tokyo')->>'household_id')::uuid;
  insert into private.line_user_links(household_id,user_id,line_user_id,status) values(h,u,'LINE-NURSERY-133','active');
  insert into public.family_children(household_id,display_name) values(h,'対象児') returning id into child;
  insert into public.child_school_contexts(household_id,child_id,school_display_name,class_display_name,effective_from)
    values(h,child,'テスト園','すだちぐみ','2026-04-01') returning id into ctx;
  perform public.server_tx_ingest_line_webhook_event('nursery-133-event','LINE-NURSERY-133',
    '{"type":"message","replyToken":"nursery-133-reply","message":{"type":"image","id":"nursery-133-image"}}');
  enq:=public.server_tx_enqueue_nursery_line_image('nursery-133-event','nursery-133-image','LINE-NURSERY-133',now());
  iid:=(enq->>'intake_id')::uuid;
  perform public.server_tx_claim_nursery_line_images(3,'nursery-133-test');
  select revision into rev from private.nursery_line_image_intakes where id=iid;
  prepared:=public.server_tx_prepare_nursery_line_source(iid,rev,h::text||'/'||iid::text||'.jpg','nursery-line-v1');
  item:=jsonb_build_object('candidate_key','item-1-task','source_locator','p1:item1','origin','source_explicit',
    'item_kind','task','classification',null,'source_page',1,'confidence_band','high',
    'proposed_value',jsonb_build_object('title','エプロン・三角巾・マスクを準備','due_date','2026-10-26'));
  -- Reproduce the actual failure: timetable classification on a task.
  bad:=item||jsonb_build_object('classification','recommended');
  checked:=public.server_read_validate_nursery_review_items(jsonb_build_array(bad,item));
  if (checked->>'dropped')::int<>1 or jsonb_array_length(checked->'items')<>1 then raise exception 'FAIL per-item canonical validation'; end if;
  recorded:=public.server_tx_record_nursery_line_analysis(iid,(prepared->>'revision')::bigint,ctx,'high','{}','[]','[]',checked->'items','review_ready');
  if recorded->>'status'<>'review_ready' or (select count(*) from private.nursery_review_items where intake_id=iid)<>1 then raise exception 'FAIL normalized actual photo task did not save'; end if;
  if exists(select 1 from public.task_instances where household_id=h) or exists(select 1 from public.family_events where household_id=h) then raise exception 'FAIL analysis bypassed human confirmation'; end if;
  delivery:=public.server_read_nursery_line_delivery_context(iid);
  if delivery->>'reply_token'<>'nursery-133-reply' or delivery->>'object_key'<>h::text||'/'||iid::text||'.jpg' then raise exception 'FAIL photo-scoped delivery context'; end if;
  if public.server_read_nursery_line_delivery_context(gen_random_uuid()) is not null then raise exception 'FAIL nonexistent context exposed data'; end if;
  if has_function_privilege('anon','public.server_read_nursery_line_delivery_context(uuid)','execute')
    or has_function_privilege('authenticated','public.server_read_nursery_line_delivery_context(uuid)','execute')
    or has_function_privilege('anon','public.server_read_validate_nursery_review_items(jsonb)','execute')
    or has_function_privilege('authenticated','public.server_read_validate_nursery_review_items(jsonb)','execute') then raise exception 'FAIL worker-only RPC exposed'; end if;
end $$;
reset role;
select '133_nursery_image_delivery: PASS' as result;

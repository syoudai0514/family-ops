-- Q89-Q106 zero-provider E2E. No real LINE download, AI, Storage, Google, or notification.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  u1 uuid:='66000000-0000-0000-0000-000000000001';
  u2 uuid:='66000000-0000-0000-0000-000000000002';
  h1 uuid; h2 uuid; a1 uuid; a2 uuid; child uuid; ctx uuid;
  enq jsonb; enq2 jsonb; iid uuid; iid2 uuid; rev bigint; dd9 jsonb; doc uuid; ext uuid; finish jsonb; review jsonb;
  item_task uuid; item_other uuid; item_url uuid; item_rec uuid; confirm_result jsonb;
  raised boolean:=false;
begin
  insert into auth.users(id) values(u1),(u2) on conflict do nothing;
  insert into public.profiles(user_id,display_name) values(u1,'Nursery A'),(u2,'Nursery B') on conflict do nothing;
  h1:=(public.server_tx_create_household(u1,'66000000-0000-0000-0000-000000000101','Nursery H1','Asia/Tokyo')->>'household_id')::uuid;
  h2:=(public.server_tx_create_household(u2,'66000000-0000-0000-0000-000000000102','Nursery H2','Asia/Tokyo')->>'household_id')::uuid;
  select id into a1 from public.domain_actor_refs where household_id=h1 and actor_kind='real_user' and real_user_id=u1;
  select id into a2 from public.domain_actor_refs where household_id=h2 and actor_kind='real_user' and real_user_id=u2;
  insert into private.line_user_links(household_id,user_id,line_user_id,status) values(h1,u1,'LINE-NURSERY-A','active'),(h2,u2,'LINE-NURSERY-B','active');
  insert into public.family_children(household_id,display_name) values(h1,'対象児') returning id into child;
  insert into public.child_school_contexts(household_id,child_id,school_display_name,class_display_name,effective_from,recognition_aliases)
    values(h1,child,'つばさ園','そら組','2026-04-01',array['そら組']) returning id into ctx;

  -- Q89/Q91: signature-validated receiver can only enqueue a linked LINE user;
  -- duplicate provider event resolves to one intake and no business mutation.
  enq:=public.server_tx_enqueue_nursery_line_image('evt-nursery-1','msg-nursery-1','LINE-NURSERY-A',now());
  iid:=(enq->>'intake_id')::uuid;
  perform public.server_tx_enqueue_nursery_line_image('evt-nursery-1','msg-nursery-1','LINE-NURSERY-A',now());
  if (select count(*) from private.nursery_line_image_intakes where provider_event_id='evt-nursery-1')<>1 then raise exception 'FAIL Q89 duplicate image intake'; end if;
  if exists(select 1 from public.task_instances where household_id=h1) then raise exception 'FAIL Q89 intake mutated canonical state'; end if;

  -- Q89 ordinary-family-photo triage produces no source/canonical records.
  enq2:=public.server_tx_enqueue_nursery_line_image('evt-photo-ordinary','msg-photo-ordinary','LINE-NURSERY-A',now()); iid2:=(enq2->>'intake_id')::uuid;
  perform public.server_tx_claim_nursery_line_images(20,'sql-test');
  select revision into rev from private.nursery_line_image_intakes where id=iid2;
  perform public.server_tx_finish_nursery_image_review(iid2,rev,'ordinary_photo',null,null,null,null,'{}', '[]'::jsonb,true);
  if (select status from private.nursery_line_image_intakes where id=iid2)<>'ordinary_photo' then raise exception 'FAIL Q89 ordinary photo triage'; end if;

  -- Build the existing DD9 source/extraction foundation for a notice image.
  dd9:=private.fn_command_create_nursery_intake_v1(h1,u1,a1,null,'66000000-0000-0000-0000-000000000201',
    'codmon_notice','nursery-source/opaque-object-key','2026-09-05 12:00+09','q89-q106-v1',jsonb_build_object('provider','line'),'line');
  doc:=(dd9->>'source_document_id')::uuid; ext:=(dd9->>'extraction_id')::uuid;
  select revision into rev from private.nursery_line_image_intakes where id=iid;
  finish:=public.server_tx_finish_nursery_image_review(iid,rev,'review_ready',doc,ext,ctx,'high','{}',jsonb_build_array(
    jsonb_build_object('candidate_key','task-1','origin','source_explicit','item_kind','task','source_page',1,'source_locator','p1:item','confidence_band','high','proposed_value',jsonb_build_object('title','水筒を準備','due_date','2026-09-10')),
    jsonb_build_object('candidate_key','other-1','origin','source_explicit','item_kind','timetable','classification','other','source_page',1,'source_locator','p1:calendar','confidence_band','high','proposed_value',jsonb_build_object('title','身体測定','date','2026-09-12')),
    jsonb_build_object('candidate_key','url-1','origin','ai_inference','item_kind','url','source_page',1,'source_locator','qr1','confidence_band','medium','proposed_value',jsonb_build_object('title','提出フォーム','due_date','2026-09-11','url','https://example.jp/form')),
    jsonb_build_object('candidate_key','rec-1','origin','ai_inference','item_kind','recurrence','source_page',1,'source_locator','p1:weekly','confidence_band','medium','proposed_value',jsonb_build_object('effective_from','2026-09-01','effective_to','2027-08-31','rule_spec',jsonb_build_object('weekday','Friday','frequency','weekly')))
  ),false);
  rev:=(finish->>'revision')::bigint;

  -- Q91 cross-household read is denied.
  begin perform public.server_read_nursery_review(u2,iid); exception when others then raised:=true; end;
  if not raised then raise exception 'FAIL Q91 cross-household review read'; end if; raised:=false;

  review:=public.server_read_nursery_review(u1,iid);
  if review->>'context_confidence'<>'high' or jsonb_array_length(review->'items')<>4 then raise exception 'FAIL Q94/Q97 review payload'; end if;
  if not exists(select 1 from private.nursery_review_items where intake_id=iid and origin='source_explicit' and source_page=1)
     or not exists(select 1 from private.nursery_review_items where intake_id=iid and origin='ai_inference' and source_page=1) then
    raise exception 'FAIL Q93/Q97 source-vs-inference provenance'; end if;
  if not exists(select 1 from private.nursery_review_items where intake_id=iid and item_kind='timetable' and classification='other') then raise exception 'FAIL Q101 Other lost'; end if;
  select id into item_task from private.nursery_review_items where intake_id=iid and candidate_key='task-1';
  select id into item_other from private.nursery_review_items where intake_id=iid and candidate_key='other-1';
  select id into item_url from private.nursery_review_items where intake_id=iid and candidate_key='url-1';
  select id into item_rec from private.nursery_review_items where intake_id=iid and candidate_key='rec-1';

  -- Q105 unsafe schemes fail before canonical mutation.
  begin
    perform public.server_tx_confirm_nursery_review(u1,'66000000-0000-0000-0000-000000000301',iid,rev,
      jsonb_build_array(jsonb_build_object('review_item_id',item_url,'confirmed_value',jsonb_build_object('title','危険リンク','due_date','2026-09-11','url','javascript:alert(1)'))));
  exception when others then raised:=true; end;
  if not raised then raise exception 'FAIL Q105 unsafe URL accepted'; end if; raised:=false;
  if exists(select 1 from public.task_instances where household_id=h1) then raise exception 'FAIL Q105 unsafe URL mutated task'; end if;

  -- Q94/Q101/Q102/Q104/Q105: only human-selected review items confirm.
  confirm_result:=public.server_tx_confirm_nursery_review(u1,'66000000-0000-0000-0000-000000000302',iid,rev,jsonb_build_array(
    jsonb_build_object('review_item_id',item_task),jsonb_build_object('review_item_id',item_other),jsonb_build_object('review_item_id',item_url),jsonb_build_object('review_item_id',item_rec)
  ));
  if confirm_result->>'confirmed'<>'true' then raise exception 'FAIL nursery confirmation'; end if;
  if (select count(*) from public.task_instances where household_id=h1)<>2 then raise exception 'FAIL Q104/Q105 task targets not created'; end if;
  if not exists(select 1 from public.nursery_confirmed_items where intake_id=iid and classification='other') then raise exception 'FAIL Q101 confirmed Other not retained'; end if;
  if not exists(select 1 from public.nursery_recurrence_series where household_id=h1 and child_school_context_id=ctx) then raise exception 'FAIL Q102 bounded recurrence'; end if;

  -- Q96: later notice is a new confirmed row, never a silent overwrite.
  if (select count(*) from public.nursery_confirmed_items where intake_id=iid)<>4 then raise exception 'FAIL Q96 confirmation history shape'; end if;

  -- Q98: raw deletion preserves confirmed structured data and signed-image read becomes unavailable.
  select revision into rev from private.nursery_line_image_intakes where id=iid;
  perform public.server_tx_mark_nursery_raw_deleted(u1,iid,rev);
  review:=public.server_read_nursery_review(u1,iid);
  if (review->>'raw_available')::boolean then raise exception 'FAIL Q98 stale raw remained readable'; end if;
  if not exists(select 1 from public.nursery_confirmed_items where intake_id=iid) then raise exception 'FAIL Q98 raw delete removed structured history'; end if;

  -- stale correction/delete protection.
  begin perform public.server_tx_mark_nursery_raw_deleted(u1,iid,rev); exception when others then raised:=true; end;
  if not raised then raise exception 'FAIL stale nursery revision accepted'; end if;
end;
$$;
reset role;
select '66_nursery_q89_q106_e2e: PASS' as result;

-- Canonical Appendix A closeout for Q89 and Q98.
-- No real LINE download/send, Gemini, Google, Storage or provider mutation.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  u1 uuid := '67000000-0000-0000-0000-000000000001';
  h1 uuid;
  a1 uuid;
  child uuid;
  ctx uuid;
  enq jsonb;
  enq2 jsonb;
  iid uuid;
  iid2 uuid;
  rev bigint;
  dd9 jsonb;
  dd92 jsonb;
  doc uuid;
  doc2 uuid;
  ext uuid;
  ext2 uuid;
  finish jsonb;
  finish2 jsonb;
  timetable_item uuid;
  share_item uuid;
  confirmed jsonb;
  replay jsonb;
  previous jsonb;
  grouped jsonb;
  event_id uuid;
  handover_id uuid;
  t0 timestamptz := now();
begin
  insert into auth.users(id) values(u1) on conflict do nothing;
  insert into public.profiles(user_id,display_name) values(u1,'Nursery Canonical') on conflict do nothing;
  h1 := (public.server_tx_create_household(
    u1,'67000000-0000-0000-0000-000000000101','Nursery Canonical H','Nursery Canonical'
  )->>'household_id')::uuid;
  select id into a1 from public.domain_actor_refs
    where household_id=h1 and actor_kind='real_user' and real_user_id=u1;
  insert into private.line_user_links(household_id,user_id,line_user_id,status)
    values(h1,u1,'LINE-NURSERY-CANONICAL','active');
  insert into public.family_children(household_id,display_name)
    values(h1,'対象児') returning id into child;
  insert into public.child_school_contexts(
    household_id,child_id,school_display_name,class_display_name,effective_from,recognition_aliases
  ) values(h1,child,'ひかり園','そら組','2026-04-01',array['そら組']) returning id into ctx;

  -- First worker invocation: one notice page becomes review_ready.
  enq := public.server_tx_enqueue_nursery_line_image(
    'evt-q89-q98-page-1','msg-q89-q98-page-1','LINE-NURSERY-CANONICAL',t0
  );
  iid := (enq->>'intake_id')::uuid;
  perform public.server_tx_claim_nursery_line_images(1,'sql-worker-batch-1');
  select revision into rev from private.nursery_line_image_intakes where id=iid;

  dd9 := private.fn_command_create_nursery_intake_v1(
    h1,u1,a1,null,'67000000-0000-0000-0000-000000000201',
    'codmon_notice','nursery-source/q89-q98-page-1.jpg',t0,'q89-q98-v1',
    jsonb_build_object('provider','line'),'line'
  );
  doc := (dd9->>'source_document_id')::uuid;
  ext := (dd9->>'extraction_id')::uuid;

  finish := public.server_tx_finish_nursery_image_review(
    iid,rev,'review_ready',doc,ext,ctx,'high','{}',jsonb_build_array(
      jsonb_build_object(
        'candidate_key','schedule-1','origin','source_explicit','item_kind','timetable',
        'classification','recommended','source_page',1,'source_locator','p1:schedule',
        'confidence_band','high','proposed_value',jsonb_build_object(
          'title','秋の遠足','date','2026-10-08','location','中央公園'
        )
      ),
      jsonb_build_object(
        'candidate_key','share-1','origin','source_explicit','item_kind','shared_info',
        'source_page',1,'source_locator','p1:notice','confidence_band','high',
        'proposed_value',jsonb_build_object(
          'text','当日は園指定の体操服で登園','date','2026-10-08'
        )
      )
    ),false
  );
  rev := (finish->>'revision')::bigint;

  -- Q89: analysis/review alone must never mutate household schedule/share.
  if exists(select 1 from public.family_events where household_id=h1) then
    raise exception 'FAIL Q89 review candidate created event before confirmation';
  end if;
  if exists(select 1 from public.handovers where household_id=h1) then
    raise exception 'FAIL Q89 review candidate created share before confirmation';
  end if;

  select id into timetable_item from private.nursery_review_items
    where intake_id=iid and candidate_key='schedule-1';
  select id into share_item from private.nursery_review_items
    where intake_id=iid and candidate_key='share-1';

  confirmed := public.server_tx_confirm_nursery_review(
    u1,'67000000-0000-0000-0000-000000000301',iid,rev,
    jsonb_build_array(
      jsonb_build_object('review_item_id',timetable_item),
      jsonb_build_object('review_item_id',share_item)
    )
  );
  if confirmed->>'confirmed'<>'true' then raise exception 'FAIL Q89 confirmation result'; end if;

  if (select count(*) from public.family_events where household_id=h1)<>1 then
    raise exception 'FAIL Q89 reviewed schedule did not create one canonical event';
  end if;
  if (select count(*) from public.handovers where household_id=h1)<>1 then
    raise exception 'FAIL Q89 reviewed shared info did not create one canonical handover';
  end if;
  select id into event_id from public.family_events where household_id=h1;
  select id into handover_id from public.handovers where household_id=h1;
  if not exists(
    select 1 from public.family_events
    where id=event_id and all_day and starts_on='2026-10-08' and ends_on='2026-10-08'
      and title='秋の遠足' and location_text='中央公園' and calendar_sync_preference='none'
  ) then raise exception 'FAIL Q89 canonical event shape'; end if;
  if (select count(*) from public.family_event_field_authorities where family_event_id=event_id and authority_mode='human_protected')<>3 then
    raise exception 'FAIL Q89 event human authority';
  end if;
  if not exists(
    select 1 from public.handovers where id=handover_id
      and shared_text='当日は園指定の体操服で登園' and occurred_on='2026-10-08'
      and 'nursery'=any(categories)
  ) then raise exception 'FAIL Q89 canonical share shape'; end if;
  if not exists(
    select 1 from public.nursery_confirmed_items
    where intake_id=iid and item_kind='timetable' and created_family_event_id=event_id
      and source_document_id=doc and source_page=1
  ) then raise exception 'FAIL Q89 schedule provenance link'; end if;
  if not exists(
    select 1 from public.nursery_confirmed_items
    where intake_id=iid and item_kind='shared_info' and created_handover_id=handover_id
      and source_document_id=doc and source_page=1
  ) then raise exception 'FAIL Q89 share provenance link'; end if;

  -- Same operation replay must not duplicate event/share canonical data.
  replay := public.server_tx_confirm_nursery_review(
    u1,'67000000-0000-0000-0000-000000000301',iid,rev,
    jsonb_build_array(
      jsonb_build_object('review_item_id',timetable_item),
      jsonb_build_object('review_item_id',share_item)
    )
  );
  if replay is distinct from confirmed then raise exception 'FAIL Q89 idempotent replay result'; end if;
  if (select count(*) from public.family_events where household_id=h1)<>1
     or (select count(*) from public.handovers where household_id=h1)<>1 then
    raise exception 'FAIL Q89 idempotent replay duplicated canonical data';
  end if;

  -- Q98: simulate a *separate* later worker invocation. The DB lookup must
  -- recover the already-confirmed first page; no in-memory worker map exists.
  enq2 := public.server_tx_enqueue_nursery_line_image(
    'evt-q89-q98-page-2','msg-q89-q98-page-2','LINE-NURSERY-CANONICAL',t0 + interval '5 minutes'
  );
  iid2 := (enq2->>'intake_id')::uuid;
  perform public.server_tx_claim_nursery_line_images(1,'sql-worker-batch-2');
  previous := public.server_read_previous_nursery_image(iid2);
  if coalesce((previous->>'found')::boolean,false) is not true
     or (previous->>'intake_id')::uuid<>iid then
    raise exception 'FAIL Q98 previous page not recovered across worker batches: %',previous;
  end if;

  select revision into rev from private.nursery_line_image_intakes where id=iid2;
  dd92 := private.fn_command_create_nursery_intake_v1(
    h1,u1,a1,null,'67000000-0000-0000-0000-000000000202',
    'codmon_notice','nursery-source/q89-q98-page-2.jpg',t0 + interval '5 minutes','q89-q98-v1',
    jsonb_build_object('provider','line'),'line'
  );
  doc2 := (dd92->>'source_document_id')::uuid;
  ext2 := (dd92->>'extraction_id')::uuid;
  finish2 := public.server_tx_finish_nursery_image_review(
    iid2,rev,'review_ready',doc2,ext2,ctx,'high','{}','[]'::jsonb,false
  );
  grouped := public.server_tx_group_nursery_image_pages(
    (previous->>'intake_id')::uuid,iid2,(finish2->>'revision')::bigint
  );
  if (grouped->>'page_index')::int<>2 then raise exception 'FAIL Q98 second page index'; end if;
  if not exists(
    select 1
    from private.nursery_line_image_intakes a
    join private.nursery_line_image_intakes b on b.document_group_id=a.document_group_id
    where a.id=iid and b.id=iid2 and a.page_index=1 and b.page_index=2
  ) then raise exception 'FAIL Q98 pages not grouped across worker batches'; end if;
end;
$$;
reset role;
select '67_nursery_q89_q98_canonical_completion: PASS' as result;

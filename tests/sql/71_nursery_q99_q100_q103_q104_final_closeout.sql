-- Appendix A final Nursery closeout for Q99/Q100/Q103/Q104.
-- No real LINE, AI, Storage or Google provider mutation.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  u1 uuid := '71000000-0000-0000-0000-000000000001';
  u2 uuid := '71000000-0000-0000-0000-000000000002';
  h1 uuid; h2 uuid; a1 uuid; a2 uuid;
  child1 uuid; child2 uuid; ctx1 uuid; ctx2 uuid;
  e jsonb; i uuid; r bigint; d jsonb; doc uuid; ext uuid; f jsonb;
  review_item uuid; rec_item uuid; ex_item uuid; sub_hidden uuid; sub_calendar uuid;
  series uuid; original_from date; original_to date;
  resolved jsonb; raised boolean := false;
  t0 timestamptz := now();
begin
  insert into auth.users(id) values(u1),(u2) on conflict do nothing;
  insert into public.profiles(user_id,display_name)
    values(u1,'Nursery Final A'),(u2,'Nursery Final B') on conflict do nothing;
  h1 := (public.server_tx_create_household(u1,'71000000-0000-0000-0000-000000000101','Nursery Final H1','Asia/Tokyo')->>'household_id')::uuid;
  h2 := (public.server_tx_create_household(u2,'71000000-0000-0000-0000-000000000102','Nursery Final H2','Asia/Tokyo')->>'household_id')::uuid;
  select id into a1 from public.domain_actor_refs where household_id=h1 and actor_kind='real_user' and real_user_id=u1;
  select id into a2 from public.domain_actor_refs where household_id=h2 and actor_kind='real_user' and real_user_id=u2;
  insert into private.line_user_links(household_id,user_id,line_user_id,status)
    values(h1,u1,'LINE-NURSERY-FINAL-A','active'),(h2,u2,'LINE-NURSERY-FINAL-B','active');
  insert into public.family_children(household_id,display_name) values(h1,'対象児A') returning id into child1;
  insert into public.family_children(household_id,display_name) values(h2,'対象児B') returning id into child2;
  insert into public.child_school_contexts(household_id,child_id,school_display_name,class_display_name,effective_from,recognition_aliases)
    values(h1,child1,'ひかり園','そら組','2026-04-01',array['そら組']) returning id into ctx1;
  insert into public.child_school_contexts(household_id,child_id,school_display_name,class_display_name,effective_from,recognition_aliases)
    values(h2,child2,'別の園','別の組','2026-04-01',array['別の組']) returning id into ctx2;

  -- Q100: only ambiguous fields are asked. Confirmation is blocked until the
  -- exact ambiguity is resolved, and a context from another household is denied.
  e := public.server_tx_enqueue_nursery_line_image('evt-final-ambiguity','msg-final-ambiguity','LINE-NURSERY-FINAL-A',t0);
  i := (e->>'intake_id')::uuid;
  perform public.server_tx_claim_nursery_line_images(1,'sql-final-ambiguity');
  select revision into r from private.nursery_line_image_intakes where id=i;
  d := private.fn_command_create_nursery_intake_v1(
    h1,u1,a1,null,'71000000-0000-0000-0000-000000000201','codmon_notice',
    'nursery-source/final-ambiguity.jpg',t0,'final-v1','{}','line'
  );
  doc := (d->>'source_document_id')::uuid; ext := (d->>'extraction_id')::uuid;
  f := public.server_tx_finish_nursery_image_review(
    i,r,'needs_clarification',doc,ext,null,'low',array['child','class'],
    jsonb_build_array(jsonb_build_object(
      'candidate_key','todo-ambiguity','origin','source_explicit','item_kind','task',
      'source_page',1,'source_locator','p1:todo','confidence_band','high',
      'proposed_value',jsonb_build_object('title','着替えを準備','due_date','2026-09-12')
    )),false
  );
  r := (f->>'revision')::bigint;
  select id into review_item from private.nursery_review_items where intake_id=i and candidate_key='todo-ambiguity';
  begin
    perform public.server_tx_confirm_nursery_review(
      u1,'71000000-0000-0000-0000-000000000301',i,r,
      jsonb_build_array(jsonb_build_object('review_item_id',review_item))
    );
  exception when others then raised := true; end;
  if not raised then raise exception 'FAIL Q100 confirmation bypassed ambiguity'; end if;
  raised := false;

  begin
    perform public.server_tx_resolve_nursery_ambiguity(u1,i,r,ctx2,array['child','class']);
  exception when others then raised := true; end;
  if not raised then raise exception 'FAIL Q100 cross-household context accepted'; end if;
  raised := false;

  resolved := public.server_tx_resolve_nursery_ambiguity(u1,i,r,ctx1,array['child','class']);
  if resolved->>'status' <> 'review_ready'
     or jsonb_array_length(resolved->'ambiguity_fields') <> 0
     or (resolved->>'child_school_context_id')::uuid <> ctx1 then
    raise exception 'FAIL Q100 exact ambiguity resolution: %', resolved;
  end if;

  -- Q99: service-role/direct-DB callers cannot turn nursery_review_items into
  -- an arbitrary durable channel. Unknown/nested payloads, PII-shaped metadata,
  -- and AI-selected Calendar choice all fail at the DB boundary.
  begin
    insert into private.nursery_review_items(
      household_id,intake_id,candidate_key,origin,item_kind,classification,
      source_document_id,source_page,source_locator,proposed_value,confidence_band
    ) values(
      h1,i,'bad-extra','ai_inference','task',null,doc,1,'p1:bad',
      jsonb_build_object('title','通常タイトル','due_date','2026-09-12','notes_dump',jsonb_build_object('other_children','secret')),
      'medium'
    );
  exception when others then raised := true; end;
  if not raised then raise exception 'FAIL Q99 arbitrary nested review payload accepted'; end if;
  raised := false;

  begin
    insert into private.nursery_review_items(
      household_id,intake_id,candidate_key,origin,item_kind,classification,
      source_document_id,source_page,source_locator,proposed_value,confidence_band
    ) values(
      h1,i,'bad calendar choice','ai_inference','submission',null,doc,1,'p1:submission',
      jsonb_build_object('title','提出書類','due_date','2026-09-15','add_to_calendar',true),
      'medium'
    );
  exception when others then raised := true; end;
  if not raised then raise exception 'FAIL Q99/Q104 AI preselected Calendar or free candidate key accepted'; end if;
  raised := false;

  -- Q103 base recurrence: human confirmation creates one bounded series.
  e := public.server_tx_enqueue_nursery_line_image('evt-final-recurrence','msg-final-recurrence','LINE-NURSERY-FINAL-A',t0+interval '1 hour');
  i := (e->>'intake_id')::uuid;
  perform public.server_tx_claim_nursery_line_images(1,'sql-final-recurrence');
  select revision into r from private.nursery_line_image_intakes where id=i;
  d := private.fn_command_create_nursery_intake_v1(
    h1,u1,a1,null,'71000000-0000-0000-0000-000000000202','codmon_notice',
    'nursery-source/final-recurrence.jpg',t0+interval '1 hour','final-v1','{}','line'
  );
  doc := (d->>'source_document_id')::uuid; ext := (d->>'extraction_id')::uuid;
  f := public.server_tx_finish_nursery_image_review(
    i,r,'review_ready',doc,ext,ctx1,'high','{}',jsonb_build_array(jsonb_build_object(
      'candidate_key','recurrence-weekly','origin','source_explicit','item_kind','recurrence',
      'source_page',1,'source_locator','p1:weekly','confidence_band','high',
      'proposed_value',jsonb_build_object(
        'effective_from','2026-09-01','effective_to','2027-08-31',
        'rule_spec',jsonb_build_object('frequency','weekly','weekday','Friday')
      )
    )),false
  );
  r := (f->>'revision')::bigint;
  select id into rec_item from private.nursery_review_items where intake_id=i and candidate_key='recurrence-weekly';
  perform public.server_tx_confirm_nursery_review(
    u1,'71000000-0000-0000-0000-000000000302',i,r,
    jsonb_build_array(jsonb_build_object('review_item_id',rec_item))
  );
  select id,effective_from,effective_to into series,original_from,original_to
    from public.nursery_recurrence_series where household_id=h1 order by created_at desc limit 1;
  if series is null then raise exception 'FAIL Q103 base series missing'; end if;

  -- A later notice changes exactly one occurrence. The base series remains
  -- active and unchanged; the exception is a separate canonical row.
  e := public.server_tx_enqueue_nursery_line_image('evt-final-exception','msg-final-exception','LINE-NURSERY-FINAL-A',t0+interval '2 hours');
  i := (e->>'intake_id')::uuid;
  perform public.server_tx_claim_nursery_line_images(1,'sql-final-exception');
  select revision into r from private.nursery_line_image_intakes where id=i;
  d := private.fn_command_create_nursery_intake_v1(
    h1,u1,a1,null,'71000000-0000-0000-0000-000000000203','codmon_notice',
    'nursery-source/final-exception.jpg',t0+interval '2 hours','final-v1','{}','line'
  );
  doc := (d->>'source_document_id')::uuid; ext := (d->>'extraction_id')::uuid;
  f := public.server_tx_finish_nursery_image_review(
    i,r,'review_ready',doc,ext,ctx1,'high','{}',jsonb_build_array(jsonb_build_object(
      'candidate_key','exception-one-day','origin','source_explicit','item_kind','exception',
      'source_page',1,'source_locator','p1:exception','confidence_band','high',
      'proposed_value',jsonb_build_object(
        'series_id',series::text,'occurrence_date','2026-10-09','action','skip'
      )
    )),false
  );
  r := (f->>'revision')::bigint;
  select id into ex_item from private.nursery_review_items where intake_id=i and candidate_key='exception-one-day';
  perform public.server_tx_confirm_nursery_review(
    u1,'71000000-0000-0000-0000-000000000303',i,r,
    jsonb_build_array(jsonb_build_object('review_item_id',ex_item))
  );
  if not exists(
    select 1 from public.nursery_recurrence_series
    where id=series and active and effective_from=original_from and effective_to=original_to
  ) then raise exception 'FAIL Q103 one-occurrence exception destroyed base series'; end if;
  if (select count(*) from public.nursery_recurrence_exceptions where series_id=series) <> 1
     or not exists(
       select 1 from public.nursery_recurrence_exceptions
       where series_id=series and occurrence_date='2026-10-09'
         and exception_value->>'action'='skip'
     ) then raise exception 'FAIL Q103 one-occurrence exception missing'; end if;

  -- Q104: both candidates become due Todos. Calendar starts OFF for both; only
  -- the second human-confirmed value opts in and becomes `special`.
  e := public.server_tx_enqueue_nursery_line_image('evt-final-submission','msg-final-submission','LINE-NURSERY-FINAL-A',t0+interval '3 hours');
  i := (e->>'intake_id')::uuid;
  perform public.server_tx_claim_nursery_line_images(1,'sql-final-submission');
  select revision into r from private.nursery_line_image_intakes where id=i;
  d := private.fn_command_create_nursery_intake_v1(
    h1,u1,a1,null,'71000000-0000-0000-0000-000000000204','codmon_notice',
    'nursery-source/final-submission.jpg',t0+interval '3 hours','final-v1','{}','line'
  );
  doc := (d->>'source_document_id')::uuid; ext := (d->>'extraction_id')::uuid;
  f := public.server_tx_finish_nursery_image_review(
    i,r,'review_ready',doc,ext,ctx1,'high','{}',jsonb_build_array(
      jsonb_build_object(
        'candidate_key','submission-hidden','origin','source_explicit','item_kind','submission',
        'source_page',1,'source_locator','p1:submission1','confidence_band','high',
        'proposed_value',jsonb_build_object('title','健康調査票を提出','due_date','2026-09-20')
      ),
      jsonb_build_object(
        'candidate_key','submission-calendar','origin','source_explicit','item_kind','submission',
        'source_page',1,'source_locator','p1:submission2','confidence_band','high',
        'proposed_value',jsonb_build_object('title','遠足同意書を提出','due_date','2026-09-22')
      )
    ),false
  );
  r := (f->>'revision')::bigint;
  select id into sub_hidden from private.nursery_review_items where intake_id=i and candidate_key='submission-hidden';
  select id into sub_calendar from private.nursery_review_items where intake_id=i and candidate_key='submission-calendar';
  perform public.server_tx_confirm_nursery_review(
    u1,'71000000-0000-0000-0000-000000000304',i,r,
    jsonb_build_array(
      jsonb_build_object('review_item_id',sub_hidden,'confirmed_value',jsonb_build_object(
        'title','健康調査票を提出','due_date','2026-09-20','add_to_calendar',false
      )),
      jsonb_build_object('review_item_id',sub_calendar,'confirmed_value',jsonb_build_object(
        'title','遠足同意書を提出','due_date','2026-09-22','add_to_calendar',true
      ))
    )
  );
  if not exists(
    select 1 from public.nursery_confirmed_items n
    join public.task_instances t on t.household_id=n.household_id and t.id=n.created_task_id
    where n.review_item_id=sub_hidden and n.item_kind='submission'
      and t.title='健康調査票を提出' and t.scheduled_date='2026-09-20'
      and t.calendar_visibility='hidden'
  ) then raise exception 'FAIL Q104 default Calendar-off submission Todo'; end if;
  if not exists(
    select 1 from public.nursery_confirmed_items n
    join public.task_instances t on t.household_id=n.household_id and t.id=n.created_task_id
    where n.review_item_id=sub_calendar and n.item_kind='submission'
      and t.title='遠足同意書を提出' and t.scheduled_date='2026-09-22'
      and t.calendar_visibility='special'
  ) then raise exception 'FAIL Q104 explicit Calendar-on submission Todo'; end if;
end;
$$;

reset role;
select '71_nursery_q99_q100_q103_q104_final_closeout: PASS' as result;

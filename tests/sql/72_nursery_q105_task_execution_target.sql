-- Appendix A Q105: reviewed URL / QR / destination attaches to the exact Todo.
-- Human confirmation is the only promotion boundary; unsafe schemes fail.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  u uuid := '72000000-0000-0000-0000-000000000001';
  h uuid; a uuid; child uuid; ctx uuid;
  e jsonb; intake uuid; rev bigint; source_result jsonb; doc uuid; ext uuid; finish jsonb;
  url_item uuid; destination_item uuid; url_task uuid; destination_task uuid;
  t0 timestamptz := now();
  raised boolean := false;
begin
  insert into auth.users(id) values(u) on conflict do nothing;
  insert into public.profiles(user_id,display_name) values(u,'Q105 Parent') on conflict do nothing;
  h := (public.server_tx_create_household(
    u,'72000000-0000-0000-0000-000000000101','Q105 Household','Asia/Tokyo'
  )->>'household_id')::uuid;
  select id into a from public.domain_actor_refs
    where household_id=h and actor_kind='real_user' and real_user_id=u;
  insert into private.line_user_links(household_id,user_id,line_user_id,status)
    values(h,u,'LINE-Q105','active');
  insert into public.family_children(household_id,display_name)
    values(h,'Q105 Child') returning id into child;
  insert into public.child_school_contexts(
    household_id,child_id,school_display_name,class_display_name,effective_from,recognition_aliases
  ) values(h,child,'ひかり園','そら組','2026-04-01',array['そら組']) returning id into ctx;

  e := public.server_tx_enqueue_nursery_line_image('evt-q105','msg-q105','LINE-Q105',t0);
  intake := (e->>'intake_id')::uuid;
  perform public.server_tx_claim_nursery_line_images(1,'sql-q105');
  select revision into rev from private.nursery_line_image_intakes where id=intake;

  source_result := private.fn_command_create_nursery_intake_v1(
    h,u,a,null,'72000000-0000-0000-0000-000000000201','codmon_notice',
    'nursery-source/q105.jpg',t0,'q105-v1','{}','line'
  );
  doc := (source_result->>'source_document_id')::uuid;
  ext := (source_result->>'extraction_id')::uuid;

  finish := public.server_tx_finish_nursery_image_review(
    intake,rev,'review_ready',doc,ext,ctx,'high','{}',jsonb_build_array(
      jsonb_build_object(
        'candidate_key','execution-url','origin','source_explicit','item_kind','url',
        'source_page',1,'source_locator','p1:url1','confidence_band','high',
        'proposed_value',jsonb_build_object(
          'title','Webフォームから欠席連絡','due_date','2026-09-25',
          'url','https://example.invalid/absence'
        )
      ),
      jsonb_build_object(
        'candidate_key','execution-destination','origin','source_explicit','item_kind','url',
        'source_page',1,'source_locator','p1:dest1','confidence_band','high',
        'proposed_value',jsonb_build_object(
          'title','申込書を提出','due_date','2026-09-26',
          'destination','園事務室の提出箱'
        )
      )
    ),false
  );
  rev := (finish->>'revision')::bigint;
  select id into url_item from private.nursery_review_items
    where intake_id=intake and candidate_key='execution-url';
  select id into destination_item from private.nursery_review_items
    where intake_id=intake and candidate_key='execution-destination';

  perform public.server_tx_confirm_nursery_review(
    u,'72000000-0000-0000-0000-000000000301',intake,rev,
    jsonb_build_array(
      jsonb_build_object('review_item_id',url_item),
      jsonb_build_object('review_item_id',destination_item)
    )
  );

  select created_task_id into url_task from public.nursery_confirmed_items
    where review_item_id=url_item;
  select created_task_id into destination_task from public.nursery_confirmed_items
    where review_item_id=destination_item;
  if url_task is null or destination_task is null or url_task=destination_task then
    raise exception 'FAIL Q105 exact Todo creation';
  end if;
  if not exists(
    select 1 from public.task_execution_targets
    where household_id=h and task_instance_id=url_task and target_kind='url'
      and url='https://example.invalid/absence' and destination is null
  ) then raise exception 'FAIL Q105 URL execution target missing'; end if;
  if not exists(
    select 1 from public.task_execution_targets
    where household_id=h and task_instance_id=destination_task and target_kind='destination'
      and destination='園事務室の提出箱' and url is null
  ) then raise exception 'FAIL Q105 destination execution target missing'; end if;

  -- Direct durable-row callers cannot bypass the URL scheme validator.
  begin
    insert into private.nursery_review_items(
      household_id,intake_id,candidate_key,origin,item_kind,classification,
      source_document_id,source_page,source_locator,proposed_value,confidence_band
    ) values(
      h,intake,'execution-unsafe','ai_inference','url',null,
      doc,1,'p1:unsafe',jsonb_build_object(
        'title','危険なリンク','due_date','2026-09-27','url','javascript:alert(1)'
      ),'low'
    );
  exception when others then raised := true; end;
  if not raised then raise exception 'FAIL Q105 unsafe durable execution target accepted'; end if;
end;
$$;

reset role;
select '72_nursery_q105_task_execution_target: PASS' as result;

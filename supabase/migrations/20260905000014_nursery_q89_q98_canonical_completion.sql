-- Issue #48 / Q89 + Q98 closeout.
--
-- Q89 requires a reviewed nursery image to become actual household schedule,
-- shared information, and preparation/Todo data. The earlier review pipeline
-- retained timetable rows as confirmed provenance but did not create a
-- canonical Family Event, and it had no reviewed shared-info item kind.
--
-- Q98 requires continuous pages to remain groupable across separate worker
-- invocations. The DB lookup already exists in migration 12; the worker wiring
-- is changed alongside this migration. This migration keeps the grouping DB
-- contract and extends the reviewed/confirmed canonical projection only.

alter table private.nursery_review_items
  drop constraint if exists nursery_review_items_item_kind_check;
alter table private.nursery_review_items
  add constraint nursery_review_items_item_kind_check
  check (item_kind in ('preparation','task','timetable','shared_info','submission','url','recurrence','exception'));

alter table public.nursery_confirmed_items
  drop constraint if exists nursery_confirmed_items_item_kind_check;
alter table public.nursery_confirmed_items
  add constraint nursery_confirmed_items_item_kind_check
  check (item_kind in ('preparation','task','timetable','shared_info','submission','url','recurrence','exception'));

alter table public.nursery_confirmed_items
  add column created_family_event_id uuid null,
  add column created_handover_id uuid null,
  add foreign key (household_id, created_family_event_id)
    references public.family_events(household_id,id),
  add foreign key (household_id, created_handover_id)
    references public.handovers(household_id,id);

create index nursery_confirmed_items_event_idx
  on public.nursery_confirmed_items(household_id,created_family_event_id)
  where created_family_event_id is not null;
create index nursery_confirmed_items_handover_idx
  on public.nursery_confirmed_items(household_id,created_handover_id)
  where created_handover_id is not null;

-- Same signature as the original worker finalizer, now accepting shared_info.
create or replace function public.server_tx_finish_nursery_image_review(
  p_intake_id uuid,p_expected_revision bigint,p_status text,p_source_document_id uuid,p_extraction_id uuid,
  p_child_school_context_id uuid,p_context_confidence text,p_ambiguity_fields text[],p_review_items jsonb,p_raw_deleted boolean default false
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  v_i private.nursery_line_image_intakes%rowtype;
  v_item jsonb;
  v_origin text;
  v_kind text;
  v_class text;
  v_page int;
  v_value jsonb;
begin
  if p_status not in ('ordinary_photo','needs_clarification','review_ready','failed') then raise exception 'NURSERY_STATUS_INVALID'; end if;
  select * into v_i from private.nursery_line_image_intakes where id=p_intake_id for update;
  if not found then raise exception 'NURSERY_INTAKE_NOT_FOUND'; end if;
  if v_i.status<>'processing' or v_i.revision<>p_expected_revision then raise exception 'NURSERY_INTAKE_STALE'; end if;
  if coalesce(p_ambiguity_fields,'{}')::text[] <@ array['nursery','child','class','date','document_group']::text[] is not true then raise exception 'NURSERY_AMBIGUITY_INVALID'; end if;
  if p_child_school_context_id is not null and not exists(
    select 1 from public.child_school_contexts c
    where c.household_id=v_i.household_id and c.id=p_child_school_context_id
  ) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if p_source_document_id is not null and not exists(
    select 1 from private.source_documents d
    where d.household_id=v_i.household_id and d.id=p_source_document_id
  ) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if p_status in ('review_ready','needs_clarification') and (p_source_document_id is null or p_extraction_id is null) then
    raise exception 'NURSERY_SOURCE_REQUIRED';
  end if;

  delete from private.nursery_review_items where intake_id=p_intake_id;
  if jsonb_typeof(coalesce(p_review_items,'[]'::jsonb))<>'array'
     or jsonb_array_length(coalesce(p_review_items,'[]'::jsonb))>64 then
    raise exception 'NURSERY_REVIEW_ITEMS_INVALID';
  end if;

  for v_item in select value from jsonb_array_elements(coalesce(p_review_items,'[]'::jsonb)) loop
    v_origin:=v_item->>'origin';
    v_kind:=v_item->>'item_kind';
    v_class:=nullif(v_item->>'classification','');
    v_page:=coalesce((v_item->>'source_page')::int,1);
    v_value:=v_item->'proposed_value';
    perform private.fn_nursery_safe_confirmed_value(v_value);
    if v_origin not in ('source_explicit','ai_inference')
       or v_kind not in ('preparation','task','timetable','shared_info','submission','url','recurrence','exception') then
      raise exception 'NURSERY_REVIEW_ITEM_INVALID';
    end if;
    if v_kind='timetable' and v_class not in ('recommended','other') then
      raise exception 'NURSERY_TIMETABLE_CLASS_REQUIRED';
    end if;
    insert into private.nursery_review_items(
      household_id,intake_id,candidate_key,origin,item_kind,classification,
      source_document_id,source_page,source_locator,proposed_value,confidence_band
    ) values(
      v_i.household_id,p_intake_id,v_item->>'candidate_key',v_origin,v_kind,v_class,
      p_source_document_id,v_page,nullif(v_item->>'source_locator',''),v_value,
      coalesce(nullif(v_item->>'confidence_band',''),'medium')
    );
  end loop;

  update private.nursery_line_image_intakes
  set status=p_status,
      source_document_id=p_source_document_id,
      extraction_id=p_extraction_id,
      child_school_context_id=p_child_school_context_id,
      context_confidence=p_context_confidence,
      ambiguity_fields=coalesce(p_ambiguity_fields,'{}'),
      raw_deleted_at=case when p_raw_deleted then now() else raw_deleted_at end,
      revision=revision+1,
      updated_at=now()
  where id=p_intake_id
  returning * into v_i;
  return jsonb_build_object('intake_id',v_i.id,'status',v_i.status,'revision',v_i.revision);
end $$;
revoke all on function public.server_tx_finish_nursery_image_review(uuid,bigint,text,uuid,uuid,uuid,text,text[],jsonb,boolean)
  from public,anon,authenticated;
grant execute on function public.server_tx_finish_nursery_image_review(uuid,bigint,text,uuid,uuid,uuid,text,text[],jsonb,boolean)
  to service_role;

-- Human confirmation is still the only promotion boundary. Timetable rows now
-- create a canonical Family Event (calendar sync preference remains none), and
-- shared_info rows reuse the existing canonical Handover mutation. Provider
-- mutation is not performed here.
create or replace function public.server_tx_confirm_nursery_review(
  p_actor_id uuid,p_operation_id uuid,p_intake_id uuid,p_expected_revision bigint,p_selected_items jsonb
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  v_i private.nursery_line_image_intakes%rowtype;
  v_actor_ref uuid;
  v_hash text;
  v_receipt private.nursery_confirmation_receipts%rowtype;
  v_item jsonb;
  v_review private.nursery_review_items%rowtype;
  v_value jsonb;
  v_title text;
  v_shared_text text;
  v_date date;
  v_task jsonb;
  v_task_id uuid;
  v_confirmed_id uuid;
  v_series_id uuid;
  v_event_id uuid;
  v_handover jsonb;
  v_handover_id uuid;
begin
  if p_actor_id is null or p_operation_id is null
     or jsonb_typeof(p_selected_items)<>'array'
     or jsonb_array_length(p_selected_items)>64 then
    raise exception 'INVALID_INPUT';
  end if;

  v_hash:=encode(sha256(convert_to(
    p_intake_id::text||'|'||p_expected_revision::text||'|'||p_selected_items::text,'UTF8'
  )),'hex');
  insert into private.nursery_confirmation_receipts(actor_id,operation_id,intake_id,request_hash)
    values(p_actor_id,p_operation_id,p_intake_id,v_hash)
    on conflict do nothing;
  if not found then
    select * into v_receipt from private.nursery_confirmation_receipts
      where actor_id=p_actor_id and operation_id=p_operation_id;
    if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result;
  end if;

  select i.* into v_i
  from private.nursery_line_image_intakes i
  join public.household_members m on m.household_id=i.household_id
  where i.id=p_intake_id and m.user_id=p_actor_id
  for update of i;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_i.status not in ('review_ready','needs_clarification') or v_i.revision<>p_expected_revision then
    raise exception 'NURSERY_INTAKE_STALE';
  end if;
  if v_i.child_school_context_id is null or cardinality(v_i.ambiguity_fields)>0 then
    raise exception 'NURSERY_CLARIFICATION_REQUIRED';
  end if;
  select id into v_actor_ref from public.domain_actor_refs
    where household_id=v_i.household_id and actor_kind='real_user' and real_user_id=p_actor_id;
  if v_actor_ref is null then raise exception 'NURSERY_ACTOR_REF_NOT_FOUND'; end if;

  for v_item in select value from jsonb_array_elements(p_selected_items) loop
    select * into v_review from private.nursery_review_items
      where intake_id=v_i.id and id=(v_item->>'review_item_id')::uuid;
    if not found then raise exception 'NURSERY_REVIEW_ITEM_STALE'; end if;

    v_value:=coalesce(v_item->'confirmed_value',v_review.proposed_value);
    perform private.fn_nursery_safe_confirmed_value(v_value);
    v_task_id:=null;
    v_event_id:=null;
    v_handover_id:=null;

    if v_review.item_kind='url' and coalesce(v_value->>'url','') !~* '^https?://[^[:space:]]+$' then
      raise exception 'NURSERY_UNSAFE_URL';
    end if;

    if v_review.item_kind='recurrence' then
      if (v_value->>'effective_to')::date < (v_value->>'effective_from')::date
         or (v_value->>'effective_to')::date > (v_value->>'effective_from')::date+366 then
        raise exception 'NURSERY_RECURRENCE_UNBOUNDED';
      end if;
      insert into public.nursery_recurrence_series(
        household_id,child_school_context_id,rule_spec,effective_from,effective_to,
        source_document_id,source_page,confirmed_by_actor_ref_id
      ) values(
        v_i.household_id,v_i.child_school_context_id,v_value->'rule_spec',
        (v_value->>'effective_from')::date,(v_value->>'effective_to')::date,
        v_review.source_document_id,v_review.source_page,v_actor_ref
      ) returning id into v_series_id;

    elsif v_review.item_kind='exception' then
      v_series_id:=(v_value->>'series_id')::uuid;
      if not exists(
        select 1 from public.nursery_recurrence_series s
        where s.id=v_series_id and s.household_id=v_i.household_id
          and s.child_school_context_id=v_i.child_school_context_id
      ) then raise exception 'NURSERY_SERIES_SCOPE_CONFLICT'; end if;
      insert into public.nursery_recurrence_exceptions(
        household_id,series_id,occurrence_date,exception_value,
        source_document_id,source_page,confirmed_by_actor_ref_id
      ) values(
        v_i.household_id,v_series_id,(v_value->>'occurrence_date')::date,v_value,
        v_review.source_document_id,v_review.source_page,v_actor_ref
      );

    elsif v_review.item_kind in ('task','submission','url') then
      v_title:=nullif(btrim(coalesce(v_value->>'title','')),'');
      v_date:=coalesce(nullif(v_value->>'due_date','')::date,(now() at time zone 'Asia/Tokyo')::date);
      if v_title is null then raise exception 'NURSERY_TASK_TITLE_REQUIRED'; end if;
      select public.server_tx_create_task_with_calendar(
        p_actor_id,gen_random_uuid(),v_title,'nursery',v_date,null::time,null::time,
        'hidden',null::uuid,'whole','anytime',null::jsonb
      ) into v_task;
      v_task_id:=(v_task->>'task_id')::uuid;

    elsif v_review.item_kind='preparation' then
      perform private.fn_command_confirm_school_preparation_rule_v1(
        v_i.household_id,p_actor_id,v_actor_ref,null,gen_random_uuid(),
        v_i.child_school_context_id,coalesce(v_value->'trigger_spec','{}'::jsonb),
        coalesce(v_value->'preparation_template',v_value),
        coalesce(nullif(v_value->>'effective_from','')::date,(now() at time zone 'Asia/Tokyo')::date),
        null,'pwa'
      );

    elsif v_review.item_kind='timetable' then
      v_title:=nullif(btrim(coalesce(v_value->>'title','')),'');
      begin
        v_date:=coalesce(nullif(v_value->>'date','')::date,nullif(v_value->>'due_date','')::date);
      exception when others then
        raise exception 'NURSERY_EVENT_DATE_INVALID';
      end;
      if v_title is null or v_date is null then raise exception 'NURSERY_EVENT_REQUIRED'; end if;
      insert into public.family_events(
        household_id,title,status,all_day,starts_on,ends_on,location_text,details,
        calendar_sync_preference,created_by_actor_ref_id
      ) values(
        v_i.household_id,v_title,'active',true,v_date,v_date,
        nullif(btrim(coalesce(v_value->>'location','')),''),
        nullif(btrim(coalesce(v_value->>'details','')),''),
        'none',v_actor_ref
      ) returning id into v_event_id;
      insert into public.family_event_field_authorities(
        household_id,family_event_id,field_name,authority_mode
      ) values
        (v_i.household_id,v_event_id,'title','human_protected'),
        (v_i.household_id,v_event_id,'schedule','human_protected'),
        (v_i.household_id,v_event_id,'location','human_protected');

    elsif v_review.item_kind='shared_info' then
      v_shared_text:=nullif(btrim(coalesce(v_value->>'text',v_value->>'title','')),'');
      begin
        v_date:=coalesce(nullif(v_value->>'date','')::date,(now() at time zone 'Asia/Tokyo')::date);
      exception when others then
        raise exception 'NURSERY_SHARED_DATE_INVALID';
      end;
      if v_shared_text is null then raise exception 'NURSERY_SHARED_TEXT_REQUIRED'; end if;
      select public.server_tx_create_handover(
        p_actor_id,gen_random_uuid(),v_shared_text,'other',array['nursery'],v_date
      ) into v_handover;
      v_handover_id:=(v_handover->>'handover_id')::uuid;
    end if;

    insert into public.nursery_confirmed_items(
      household_id,child_school_context_id,intake_id,review_item_id,item_kind,classification,
      confirmed_value,source_document_id,source_page,origin,confirmed_by_actor_ref_id,
      created_task_id,created_family_event_id,created_handover_id
    ) values(
      v_i.household_id,v_i.child_school_context_id,v_i.id,v_review.id,v_review.item_kind,
      v_review.classification,v_value,v_review.source_document_id,v_review.source_page,
      case when v_value is distinct from v_review.proposed_value then 'human_edit' else v_review.origin end,
      v_actor_ref,v_task_id,v_event_id,v_handover_id
    ) returning id into v_confirmed_id;
  end loop;

  update private.nursery_line_image_intakes
    set status='confirmed',revision=revision+1,updated_at=now()
    where id=v_i.id;
  update private.nursery_confirmation_receipts
    set result=jsonb_build_object('confirmed',true,'intake_id',v_i.id)
    where actor_id=p_actor_id and operation_id=p_operation_id;
  return jsonb_build_object('confirmed',true,'intake_id',v_i.id);
end $$;
revoke all on function public.server_tx_confirm_nursery_review(uuid,uuid,uuid,bigint,jsonb)
  from public,anon,authenticated;
grant execute on function public.server_tx_confirm_nursery_review(uuid,uuid,uuid,bigint,jsonb)
  to service_role;

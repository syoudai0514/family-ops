-- Issue #48 Q94/Q95 closeout.
-- Later nursery notices are review candidates first. Only after human confirmation
-- may a previously confirmed schedule/preparation rule be changed. The prior
-- confirmed item remains append-only provenance and the new row points to it via
-- supersedes_confirmed_item_id (migration 12).

alter table public.nursery_confirmed_items
  add column created_preparation_rule_id uuid null
    references public.school_preparation_rules(id);
create index nursery_confirmed_items_preparation_rule_idx
  on public.nursery_confirmed_items(household_id,created_preparation_rule_id)
  where created_preparation_rule_id is not null;

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
  v_previous public.nursery_confirmed_items%rowtype;
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
  v_prep jsonb;
  v_preparation_rule_id uuid;
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

    v_previous:=null;
    if v_review.previous_confirmed_item_id is not null then
      select * into v_previous from public.nursery_confirmed_items
      where id=v_review.previous_confirmed_item_id
        and household_id=v_i.household_id
        and child_school_context_id=v_i.child_school_context_id;
      if not found then raise exception 'NURSERY_PREVIOUS_CONFIRMATION_SCOPE_CONFLICT'; end if;
    end if;

    v_value:=coalesce(v_item->'confirmed_value',v_review.proposed_value);
    perform private.fn_nursery_safe_confirmed_value(v_value);
    v_task_id:=null;
    v_event_id:=null;
    v_handover_id:=null;
    v_preparation_rule_id:=null;

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
      -- A later, human-confirmed preparation change replaces the active rule
      -- by deactivating the exact prior rule. The old row remains immutable
      -- history; inference alone never reaches this branch.
      if v_previous.id is not null and v_previous.created_preparation_rule_id is not null then
        perform 1 from public.school_preparation_rules r
        where r.id=v_previous.created_preparation_rule_id
          and r.household_id=v_i.household_id
          and r.child_school_context_id=v_i.child_school_context_id
        for update;
        if not found then raise exception 'NURSERY_PREPARATION_RULE_SCOPE_CONFLICT'; end if;
        update public.school_preparation_rules
          set active=false
          where id=v_previous.created_preparation_rule_id;
      end if;
      select private.fn_command_confirm_school_preparation_rule_v1(
        v_i.household_id,p_actor_id,v_actor_ref,null,gen_random_uuid(),
        v_i.child_school_context_id,coalesce(v_value->'trigger_spec','{}'::jsonb),
        coalesce(v_value->'preparation_template',v_value),
        coalesce(nullif(v_value->>'effective_from','')::date,(now() at time zone 'Asia/Tokyo')::date),
        nullif(v_value->>'effective_to','')::date,'pwa'
      ) into v_prep;
      v_preparation_rule_id:=(v_prep->>'school_preparation_rule_id')::uuid;

    elsif v_review.item_kind='timetable' then
      v_title:=nullif(btrim(coalesce(v_value->>'title','')),'');
      begin
        v_date:=coalesce(nullif(v_value->>'date','')::date,nullif(v_value->>'due_date','')::date);
      exception when others then
        raise exception 'NURSERY_EVENT_DATE_INVALID';
      end;
      if v_title is null or v_date is null then raise exception 'NURSERY_EVENT_REQUIRED'; end if;

      if v_previous.id is not null and v_previous.created_family_event_id is not null then
        -- Human confirmed diff: update the exact previously-created canonical
        -- Family Event under row lock, instead of creating a duplicate event.
        select id into v_event_id from public.family_events
          where id=v_previous.created_family_event_id
            and household_id=v_i.household_id
          for update;
        if v_event_id is null then raise exception 'NURSERY_FAMILY_EVENT_SCOPE_CONFLICT'; end if;
        update public.family_events
          set title=v_title,
              status='active',
              all_day=true,
              starts_on=v_date,
              ends_on=v_date,
              starts_at=null,
              ends_at=null,
              location_text=nullif(btrim(coalesce(v_value->>'location','')),''),
              details=nullif(btrim(coalesce(v_value->>'details','')),''),
              revision=revision+1
          where id=v_event_id and household_id=v_i.household_id;
      else
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
      end if;

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
      created_task_id,created_family_event_id,created_handover_id,created_preparation_rule_id
    ) values(
      v_i.household_id,v_i.child_school_context_id,v_i.id,v_review.id,v_review.item_kind,
      v_review.classification,v_value,v_review.source_document_id,v_review.source_page,
      case when v_value is distinct from v_review.proposed_value then 'human_edit' else v_review.origin end,
      v_actor_ref,v_task_id,v_event_id,v_handover_id,v_preparation_rule_id
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

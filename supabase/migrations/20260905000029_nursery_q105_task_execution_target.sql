-- Issue #48 / Appendix A Q105 closeout.
-- A reviewed URL / QR destination is not merely provenance: after human
-- confirmation it becomes a household-visible execution target on the exact
-- canonical Todo. Low-confidence candidates remain review-only; the PWA keeps
-- them unselected by default. No external navigation/provider side effect is
-- performed by this migration.

create table public.task_execution_targets (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  task_instance_id uuid not null,
  target_kind text not null check (target_kind in ('url','destination')),
  label text null check (label is null or (length(btrim(label)) between 1 and 160)),
  url text null,
  destination text null,
  created_by_actor_ref_id uuid not null,
  created_at timestamptz not null default now(),
  unique (household_id,task_instance_id),
  foreign key (household_id,task_instance_id)
    references public.task_instances(household_id,id) on delete cascade,
  foreign key (household_id,created_by_actor_ref_id)
    references public.domain_actor_refs(household_id,id),
  check (
    (target_kind='url' and url ~* '^https?://[^[:space:]]+$' and destination is null)
    or
    (target_kind='destination' and url is null and length(btrim(destination)) between 1 and 500)
  )
);

alter table public.task_execution_targets enable row level security;
grant select on public.task_execution_targets to authenticated;
grant select,insert,update,delete on public.task_execution_targets to service_role;
create policy task_execution_targets_select on public.task_execution_targets
for select to authenticated using (public.is_household_member(household_id));
create index task_execution_targets_task_idx
  on public.task_execution_targets(household_id,task_instance_id);

create or replace function private.fn_validate_nursery_execution_target_review_v1(p_value jsonb)
returns void
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_key text;
  v_url text;
  v_destination text;
begin
  perform private.fn_nursery_safe_confirmed_value(p_value);
  if p_value is null or jsonb_typeof(p_value)<>'object'
     or octet_length(p_value::text)>2048 then
    raise exception 'NURSERY_REVIEW_VALUE_INVALID';
  end if;
  for v_key in select jsonb_object_keys(p_value) loop
    if v_key not in ('title','due_date','url','destination') then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;
    if jsonb_typeof(p_value->v_key) not in ('string','null') then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;
  end loop;
  if nullif(btrim(coalesce(p_value->>'title','')),'') is null
     or length(p_value->>'title')>240 then
    raise exception 'NURSERY_REVIEW_VALUE_INVALID';
  end if;
  v_url:=nullif(btrim(coalesce(p_value->>'url','')),'');
  v_destination:=nullif(btrim(coalesce(p_value->>'destination','')),'');
  if (v_url is null)=(v_destination is null) then
    raise exception 'NURSERY_EXECUTION_TARGET_REQUIRED';
  end if;
  if v_url is not null and v_url !~* '^https?://[^[:space:]]+$' then
    raise exception 'NURSERY_UNSAFE_URL';
  end if;
  if v_destination is not null and length(v_destination)>500 then
    raise exception 'NURSERY_REVIEW_VALUE_INVALID';
  end if;
end;
$$;
revoke all on function private.fn_validate_nursery_execution_target_review_v1(jsonb)
  from public,anon,authenticated;
grant execute on function private.fn_validate_nursery_execution_target_review_v1(jsonb) to service_role;

create or replace function private.fn_guard_nursery_review_item_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.candidate_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$' then
    raise exception 'NURSERY_REVIEW_CANDIDATE_KEY_INVALID';
  end if;
  if new.source_locator is not null
     and new.source_locator !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$' then
    raise exception 'NURSERY_SOURCE_LOCATOR_INVALID';
  end if;
  if new.item_kind='timetable' then
    if new.classification not in ('recommended','other') then
      raise exception 'NURSERY_TIMETABLE_CLASS_REQUIRED';
    end if;
  elsif new.classification is not null then
    raise exception 'NURSERY_CLASSIFICATION_INVALID';
  end if;

  if new.item_kind='url' then
    perform private.fn_validate_nursery_execution_target_review_v1(new.proposed_value);
  else
    perform private.fn_validate_nursery_review_value_by_kind_v1(new.item_kind,new.proposed_value);
  end if;
  return new;
end;
$$;

create or replace function private.fn_attach_nursery_execution_target_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_url text;
  v_destination text;
  v_kind text;
begin
  if new.item_kind<>'url' then return new; end if;
  if new.created_task_id is null then raise exception 'NURSERY_EXECUTION_TARGET_TASK_REQUIRED'; end if;
  perform private.fn_validate_nursery_execution_target_review_v1(new.confirmed_value - 'add_to_calendar');
  v_url:=nullif(btrim(coalesce(new.confirmed_value->>'url','')),'');
  v_destination:=nullif(btrim(coalesce(new.confirmed_value->>'destination','')),'');
  v_kind:=case when v_url is not null then 'url' else 'destination' end;

  insert into public.task_execution_targets(
    household_id,task_instance_id,target_kind,label,url,destination,created_by_actor_ref_id
  ) values(
    new.household_id,new.created_task_id,v_kind,
    nullif(btrim(coalesce(new.confirmed_value->>'title','')),''),
    v_url,v_destination,new.confirmed_by_actor_ref_id
  );
  return new;
end;
$$;
revoke all on function private.fn_attach_nursery_execution_target_v1()
  from public,anon,authenticated;
grant execute on function private.fn_attach_nursery_execution_target_v1() to service_role;

drop trigger if exists nursery_confirmed_execution_target_v1 on public.nursery_confirmed_items;
create trigger nursery_confirmed_execution_target_v1
after insert on public.nursery_confirmed_items
for each row execute function private.fn_attach_nursery_execution_target_v1();

-- Migration 15 is the latest confirmation command. Keep the same public
-- signature/idempotency/authority behavior; only replace its URL-only guard
-- with the strict URL-or-destination validator above.
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

    if v_review.item_kind='url' then
      perform private.fn_validate_nursery_execution_target_review_v1(v_value);
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

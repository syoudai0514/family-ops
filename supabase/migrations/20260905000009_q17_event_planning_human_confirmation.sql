-- Q17 literal closeout: Event = template + entered content + AI candidates +
-- human review/confirmation.  Pre-confirm data lives only in this private
-- planning draft.  The existing canonical public.family_events and linked
-- public.task_instances are mutated only by the explicit confirm command.
-- Q18 remains intact: family_events has no coordinator/owner field; each
-- selected preparation Todo carries its own assignment state.

create table private.event_planning_drafts (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  actor_id uuid not null,
  actor_ref_id uuid not null,
  template_key text not null check (template_key in ('birthday','school','medical','ceremony','trip','custom')),
  input_payload jsonb not null,
  template_candidates jsonb not null default '[]'::jsonb,
  ai_candidates jsonb not null default '[]'::jsonb,
  status text not null default 'draft' check (status in ('draft','confirmed','cancelled','expired')),
  revision bigint not null default 1 check (revision >= 1),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  family_event_id uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (household_id, actor_id) references public.household_members(household_id,user_id),
  foreign key (household_id, actor_ref_id) references public.domain_actor_refs(household_id,id),
  foreign key (household_id, family_event_id) references public.family_events(household_id,id),
  check (jsonb_typeof(input_payload)='object'),
  check (jsonb_typeof(template_candidates)='array'),
  check (jsonb_typeof(ai_candidates)='array')
);
create index event_planning_drafts_actor_idx
  on private.event_planning_drafts(actor_id,status,created_at desc);
revoke all on table private.event_planning_drafts from public,anon,authenticated;
grant select,insert,update,delete on table private.event_planning_drafts to service_role;

create or replace function private.fn_validate_event_candidate_array_v1(
  p_candidates jsonb,
  p_expected_source text
) returns void
language plpgsql
security definer
set search_path=''
as $$
declare v_item jsonb; v_ids text[] := '{}'; v_id text; v_title text;
begin
  if jsonb_typeof(p_candidates) <> 'array' or jsonb_array_length(p_candidates) > 12 then
    raise exception 'EVENT_CANDIDATES_INVALID';
  end if;
  for v_item in select value from jsonb_array_elements(p_candidates) loop
    if jsonb_typeof(v_item) <> 'object' then raise exception 'EVENT_CANDIDATES_INVALID'; end if;
    v_id := btrim(coalesce(v_item->>'candidate_id',''));
    v_title := btrim(coalesce(v_item->>'title',''));
    if char_length(v_id) not between 1 and 80
       or char_length(v_title) not between 1 and 240
       or v_item->>'source' is distinct from p_expected_source then
      raise exception 'EVENT_CANDIDATES_INVALID';
    end if;
    if v_id = any(v_ids) then raise exception 'EVENT_CANDIDATES_DUPLICATE'; end if;
    v_ids := array_append(v_ids,v_id);
  end loop;
end;
$$;
revoke all on function private.fn_validate_event_candidate_array_v1(jsonb,text)
  from public,anon,authenticated;
grant execute on function private.fn_validate_event_candidate_array_v1(jsonb,text) to service_role;

create or replace function public.server_tx_begin_event_planning_draft(
  p_actor_id uuid,
  p_operation_id uuid,
  p_template_key text,
  p_input_payload jsonb,
  p_template_candidates jsonb,
  p_ai_candidates jsonb
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_hash text;
  v_receipt private.mutation_receipts%rowtype;
  v_draft_id uuid;
  v_result jsonb;
  v_title text;
  v_event_date date;
begin
  if p_actor_id is null or p_operation_id is null
     or p_template_key not in ('birthday','school','medical','ceremony','trip','custom')
     or jsonb_typeof(p_input_payload) <> 'object' then
    raise exception 'INVALID_INPUT';
  end if;
  v_title := btrim(coalesce(p_input_payload->>'title',''));
  begin v_event_date := (p_input_payload->>'event_date')::date;
  exception when others then raise exception 'EVENT_DATE_INVALID'; end;
  if char_length(v_title) not between 1 and 240 or v_event_date is null then
    raise exception 'INVALID_INPUT';
  end if;
  if char_length(coalesce(p_input_payload->>'details','')) > 4000
     or char_length(coalesce(p_input_payload->>'location','')) > 500 then
    raise exception 'INVALID_INPUT';
  end if;

  perform private.fn_validate_event_candidate_array_v1(p_template_candidates,'template');
  perform private.fn_validate_event_candidate_array_v1(p_ai_candidates,'ai');

  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;
  v_actor_ref_id := (v_context->>'actor_ref_id')::uuid;
  v_hash := encode(sha256(convert_to(
    'event-planning-draft|' || p_template_key || '|' || p_input_payload::text,'UTF8'
  )),'hex');

  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
      values(p_actor_id,p_operation_id,'event-planning-draft',v_hash)
      on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
      where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash <> v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
    return v_receipt.result_payload;
  end loop;

  insert into private.event_planning_drafts(
    household_id,actor_id,actor_ref_id,template_key,input_payload,
    template_candidates,ai_candidates
  ) values(
    v_household_id,p_actor_id,v_actor_ref_id,p_template_key,p_input_payload,
    p_template_candidates,p_ai_candidates
  ) returning id into v_draft_id;

  v_result := jsonb_build_object(
    'draft_id',v_draft_id,
    'revision',1,
    'template_key',p_template_key,
    'input',p_input_payload,
    'template_candidates',p_template_candidates,
    'ai_candidates',p_ai_candidates,
    'status','draft'
  );
  update private.mutation_receipts
    set result_type='event_planning_draft',result_id=v_draft_id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;

create or replace function public.server_tx_confirm_event_planning_draft(
  p_actor_id uuid,
  p_operation_id uuid,
  p_draft_id uuid,
  p_expected_revision bigint,
  p_reviewed_event jsonb,
  p_selected_todos jsonb
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_draft private.event_planning_drafts%rowtype;
  v_hash text;
  v_receipt private.mutation_receipts%rowtype;
  v_event_id uuid;
  v_event_title text;
  v_event_date date;
  v_location text;
  v_details text;
  v_todo jsonb;
  v_candidate_id text;
  v_candidate_source text;
  v_todo_title text;
  v_todo_date date;
  v_assignee_user_id uuid;
  v_assignee_actor_ref_id uuid;
  v_task_id uuid;
  v_task_ids uuid[] := '{}';
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_draft_id is null
     or p_expected_revision is null or p_expected_revision < 1
     or jsonb_typeof(p_reviewed_event) <> 'object'
     or jsonb_typeof(p_selected_todos) <> 'array'
     or jsonb_array_length(p_selected_todos) > 20 then
    raise exception 'INVALID_INPUT';
  end if;
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;
  v_actor_ref_id := (v_context->>'actor_ref_id')::uuid;

  v_hash := encode(sha256(convert_to(
    'event-planning-confirm|' || p_draft_id::text || '|' || p_expected_revision::text || '|' ||
    p_reviewed_event::text || '|' || p_selected_todos::text,'UTF8'
  )),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
      values(p_actor_id,p_operation_id,'event-planning-confirm',v_hash)
      on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
      where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash <> v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
    return v_receipt.result_payload;
  end loop;

  select * into v_draft from private.event_planning_drafts
  where id=p_draft_id and household_id=v_household_id and actor_id=p_actor_id
  for update;
  if not found then raise exception 'EVENT_DRAFT_NOT_FOUND'; end if;
  if v_draft.status <> 'draft' then raise exception 'EVENT_DRAFT_NOT_EDITABLE'; end if;
  if v_draft.expires_at <= now() then
    update private.event_planning_drafts set status='expired',updated_at=now() where id=v_draft.id;
    raise exception 'EVENT_DRAFT_EXPIRED';
  end if;
  if v_draft.revision <> p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;

  v_event_title := btrim(coalesce(p_reviewed_event->>'title',''));
  begin v_event_date := (p_reviewed_event->>'event_date')::date;
  exception when others then raise exception 'EVENT_DATE_INVALID'; end;
  v_location := nullif(btrim(coalesce(p_reviewed_event->>'location','')),'');
  v_details := nullif(btrim(coalesce(p_reviewed_event->>'details','')),'');
  if char_length(v_event_title) not between 1 and 240 or v_event_date is null
     or char_length(coalesce(v_location,'')) > 500
     or char_length(coalesce(v_details,'')) > 4000 then
    raise exception 'INVALID_INPUT';
  end if;

  -- Validate every reviewed Todo against the candidate set before any
  -- canonical event/task row is created. Editing title/date/assignee is
  -- allowed; inventing an unreviewed hidden candidate id is not.
  for v_todo in select value from jsonb_array_elements(p_selected_todos) loop
    if jsonb_typeof(v_todo) <> 'object' then raise exception 'EVENT_TODO_INVALID'; end if;
    v_candidate_id := btrim(coalesce(v_todo->>'candidate_id',''));
    select c->>'source' into v_candidate_source
    from (
      select value c from jsonb_array_elements(v_draft.template_candidates)
      union all
      select value c from jsonb_array_elements(v_draft.ai_candidates)
    ) q
    where c->>'candidate_id'=v_candidate_id
    limit 1;
    if v_candidate_source is null then raise exception 'EVENT_TODO_NOT_IN_REVIEW_SET'; end if;

    v_todo_title := btrim(coalesce(v_todo->>'title',''));
    if char_length(v_todo_title) not between 1 and 240 then raise exception 'EVENT_TODO_INVALID'; end if;
    begin v_todo_date := coalesce(nullif(v_todo->>'scheduled_date','')::date,v_event_date);
    exception when others then raise exception 'EVENT_TODO_DATE_INVALID'; end;
    if v_todo_date > v_event_date then raise exception 'EVENT_TODO_AFTER_EVENT'; end if;

    v_assignee_user_id := null;
    v_assignee_actor_ref_id := null;
    if nullif(v_todo->>'planned_assignee_user_id','') is not null then
      begin v_assignee_user_id := (v_todo->>'planned_assignee_user_id')::uuid;
      exception when others then raise exception 'EVENT_TODO_ASSIGNEE_INVALID'; end;
      if not exists(select 1 from public.household_members m
        where m.household_id=v_household_id and m.user_id=v_assignee_user_id) then
        raise exception 'CROSS_HOUSEHOLD_RESOURCE';
      end if;
      select a.id into v_assignee_actor_ref_id from public.domain_actor_refs a
      where a.household_id=v_household_id and a.actor_kind='real_user'
        and a.real_user_id=v_assignee_user_id;
      if v_assignee_actor_ref_id is null then raise exception 'EVENT_TODO_ASSIGNEE_INVALID'; end if;
    end if;
  end loop;

  insert into public.family_events(
    household_id,title,status,all_day,starts_on,ends_on,location_text,details,
    calendar_sync_preference,created_by_actor_ref_id
  ) values(
    v_household_id,v_event_title,'active',true,v_event_date,v_event_date,
    v_location,v_details,'none',v_actor_ref_id
  ) returning id into v_event_id;

  insert into public.family_event_field_authorities(
    household_id,family_event_id,field_name,authority_mode
  ) values
    (v_household_id,v_event_id,'title','human_protected'),
    (v_household_id,v_event_id,'schedule','human_protected'),
    (v_household_id,v_event_id,'location','human_protected');

  for v_todo in select value from jsonb_array_elements(p_selected_todos) loop
    v_candidate_id := btrim(v_todo->>'candidate_id');
    select c->>'source' into v_candidate_source
    from (
      select value c from jsonb_array_elements(v_draft.template_candidates)
      union all
      select value c from jsonb_array_elements(v_draft.ai_candidates)
    ) q where c->>'candidate_id'=v_candidate_id limit 1;
    v_todo_title := btrim(v_todo->>'title');
    v_todo_date := coalesce(nullif(v_todo->>'scheduled_date','')::date,v_event_date);
    v_assignee_user_id := nullif(v_todo->>'planned_assignee_user_id','')::uuid;
    v_assignee_actor_ref_id := null;
    if v_assignee_user_id is not null then
      select a.id into v_assignee_actor_ref_id from public.domain_actor_refs a
      where a.household_id=v_household_id and a.actor_kind='real_user'
        and a.real_user_id=v_assignee_user_id;
    end if;

    insert into public.task_instances(
      household_id,origin,title,category,routine_phase,scheduled_date,
      planned_assignee_id,completion_mode,status,source,created_by,
      assignment_mode,assignment_source,planned_assignee_actor_ref_id,
      expectation,carryover_policy,duplicate_sensitivity,early_completion_policy,
      source_context,event_id
    ) values(
      v_household_id,'manual',v_todo_title,'イベント準備','anytime',v_todo_date,
      v_assignee_user_id,'whole','todo','event_planning',p_actor_id,
      case when v_assignee_user_id is null then 'unassigned' else 'person' end,
      'manual',v_assignee_actor_ref_id,'normal','until_deadline','normal','none',
      jsonb_build_object(
        'event_planning_draft_id',v_draft.id,
        'candidate_id',v_candidate_id,
        'candidate_source',v_candidate_source,
        'human_confirmed',true
      ),v_event_id
    ) returning id into v_task_id;
    v_task_ids := array_append(v_task_ids,v_task_id);
  end loop;

  update private.event_planning_drafts
  set status='confirmed',revision=revision+1,family_event_id=v_event_id,updated_at=now()
  where id=v_draft.id;

  v_result := jsonb_build_object(
    'family_event_id',v_event_id,
    'task_ids',to_jsonb(v_task_ids),
    'task_count',coalesce(array_length(v_task_ids,1),0),
    'status','confirmed',
    'revision',v_draft.revision+1
  );
  update private.mutation_receipts
    set result_type='family_event',result_id=v_event_id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;

revoke all on function public.server_tx_begin_event_planning_draft(uuid,uuid,text,jsonb,jsonb,jsonb)
  from public,anon,authenticated;
revoke all on function public.server_tx_confirm_event_planning_draft(uuid,uuid,uuid,bigint,jsonb,jsonb)
  from public,anon,authenticated;
grant execute on function public.server_tx_begin_event_planning_draft(uuid,uuid,text,jsonb,jsonb,jsonb) to service_role;
grant execute on function public.server_tx_confirm_event_planning_draft(uuid,uuid,uuid,bigint,jsonb,jsonb) to service_role;

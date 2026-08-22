-- Final sweep: atomic family-role swaps and editable custom-routine
-- subtask definitions.  This is deliberately forward-only: materialized
-- task/subtask rows remain historical snapshots.

alter table public.task_subtask_definitions
  add column if not exists is_active boolean not null default true;

-- Recurrence replacement already deletes future todo task instances. Once a
-- recurring instance has its canonical subtask snapshots, the child rows must
-- follow that same future-only cleanup; completed parents are never deleted by
-- those mutations and therefore retain their History unchanged.
alter table public.task_subtask_instances
  drop constraint if exists task_subtask_instances_household_id_task_instance_id_fkey;
alter table public.task_subtask_instances
  add constraint task_subtask_instances_household_id_task_instance_id_fkey
  foreign key (household_id, task_instance_id)
  references public.task_instances (household_id, id) on delete cascade;

create index if not exists task_subtask_definitions_active_definition_idx
  on public.task_subtask_definitions (household_id, task_definition_id, sort_order)
  where is_active;

-- Occurrences are compact calendar projections, but a tapped detail view may
-- safely expose the cached Google event fields. The trigger keeps projection
-- writes centralized and does not change sync/dedupe identity.
alter table public.calendar_event_occurrences
  add column if not exists description text,
  add column if not exists location text;
create or replace function private.fn_hydrate_calendar_occurrence_detail()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  select c.description,c.location into new.description,new.location
  from public.calendar_events_cache c
  where c.household_id=new.household_id and c.calendar_connection_id=new.calendar_connection_id
    and c.google_event_id=new.google_event_id;
  return new;
end $$;
drop trigger if exists calendar_occurrence_hydrate_detail on public.calendar_event_occurrences;
create trigger calendar_occurrence_hydrate_detail before insert or update of google_event_id,calendar_connection_id
on public.calendar_event_occurrences for each row execute function private.fn_hydrate_calendar_occurrence_detail();
revoke all on function private.fn_hydrate_calendar_occurrence_detail() from public,anon,authenticated;

-- A single role selection must not turn a normal two-adult household into a
-- one-role household. Lock the household's adult slots, temporarily clear the
-- target slot to satisfy the immediate unique index, then assign the former
-- holder the target member's old role before assigning the requested role.
create or replace function public.server_tx_set_family_role(
  p_actor_id uuid,p_operation_id uuid,p_user_id uuid,p_family_role text
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_household uuid; v_hash text; v_receipt record; v_result jsonb;
  v_current_role text; v_requested_holder uuid; v_swap_role text;
  v_adult_count integer; v_papa_count integer; v_mama_count integer;
begin
  if p_actor_id is null or p_operation_id is null or p_user_id is null
     or p_family_role not in ('papa','mama') then
    raise exception 'INVALID_INPUT';
  end if;
  v_hash := encode(sha256(convert_to(jsonb_build_object('user_id',p_user_id,'family_role',p_family_role)::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
  values(p_actor_id,p_operation_id,'set-family-role-v2',v_hash)
  on conflict(actor_id,operation_id) do nothing;
  if not found then
    select * into v_receipt from private.mutation_receipts
    where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result_payload;
  end if;

  select household_id into v_household from public.household_members where user_id=p_actor_id;
  if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  -- Serialise all concurrent P/M changes in this household.
  perform 1 from public.household_members
  where household_id=v_household and member_role='adult'
  order by user_id for update;
  select family_role into v_current_role from public.household_members
  where household_id=v_household and user_id=p_user_id and member_role='adult';
  if not found then
    if exists(select 1 from public.household_members where user_id=p_user_id) then
      raise exception 'CROSS_HOUSEHOLD_RESOURCE';
    end if;
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  if v_current_role is distinct from p_family_role then
    select user_id into v_requested_holder from public.household_members
    where household_id=v_household and family_role=p_family_role and user_id<>p_user_id
    for update;
    -- A newly assigned adult fills the requested slot and gives its existing
    -- holder the opposite role. Normal two-adult households always take the
    -- main swap path below.
    v_swap_role := coalesce(v_current_role, case p_family_role when 'papa' then 'mama' else 'papa' end);
    update public.household_members set family_role=null
    where household_id=v_household and user_id=p_user_id;
    if v_requested_holder is not null then
      update public.household_members set family_role=v_swap_role
      where household_id=v_household and user_id=v_requested_holder;
    end if;
    update public.household_members set family_role=p_family_role
    where household_id=v_household and user_id=p_user_id;
  end if;

  select count(*), count(*) filter(where family_role='papa'), count(*) filter(where family_role='mama')
  into v_adult_count,v_papa_count,v_mama_count
  from public.household_members where household_id=v_household and member_role='adult';
  if v_adult_count=2 and (v_papa_count<>1 or v_mama_count<>1) then
    raise exception 'FAMILY_ROLE_INVARIANT';
  end if;
  v_result:=jsonb_build_object('ok',true,'user_id',p_user_id,'family_role',p_family_role,'swapped',v_current_role is distinct from p_family_role);
  update private.mutation_receipts set result_type='household_member',result_id=p_user_id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end $$;
revoke all on function public.server_tx_set_family_role(uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.server_tx_set_family_role(uuid,uuid,uuid,text) to service_role;

-- Canonical definition mutation for the existing custom morning/evening
-- routine editor. Retired rows are kept if historical subtask instances point
-- at them; their copied instance title/required/order is never rewritten.
create or replace function public.server_tx_replace_routine_subtasks(
  p_actor_id uuid,p_operation_id uuid,p_task_definition_id uuid,p_subtasks jsonb
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_household uuid; v_hash text; v_receipt record; v_result jsonb; v_subtask jsonb;
  v_existing_id uuid; v_seen_ids uuid[] := '{}'; v_count integer := 0;
begin
  if p_actor_id is null or p_operation_id is null or p_task_definition_id is null
     or jsonb_typeof(p_subtasks) <> 'array' then raise exception 'INVALID_INPUT'; end if;
  v_hash:=encode(sha256(convert_to(jsonb_build_object('definition',p_task_definition_id,'subtasks',p_subtasks)::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
  values(p_actor_id,p_operation_id,'replace-routine-subtasks-v1',v_hash)
  on conflict(actor_id,operation_id) do nothing;
  if not found then
    select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result_payload;
  end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id;
  if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  perform 1 from public.task_definitions
  where household_id=v_household and id=p_task_definition_id and task_kind in ('morning_chore','evening_chore') for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;

  for v_subtask in select * from jsonb_array_elements(p_subtasks) loop
    if coalesce(btrim(v_subtask->>'title'),'')='' then raise exception 'INVALID_INPUT'; end if;
    if v_subtask ? 'id' and nullif(v_subtask->>'id','') is not null then
      begin v_existing_id := (v_subtask->>'id')::uuid; exception when invalid_text_representation then raise exception 'INVALID_INPUT'; end;
      update public.task_subtask_definitions
      set title=btrim(v_subtask->>'title'), required=coalesce((v_subtask->>'required')::boolean,true),
          sort_order=v_count, is_active=true
      where household_id=v_household and task_definition_id=p_task_definition_id and id=v_existing_id;
      if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
    else
      insert into public.task_subtask_definitions(household_id,task_definition_id,title,required,sort_order,is_active)
      values(v_household,p_task_definition_id,btrim(v_subtask->>'title'),coalesce((v_subtask->>'required')::boolean,true),v_count,true)
      returning id into v_existing_id;
    end if;
    v_seen_ids := array_append(v_seen_ids,v_existing_id);
    v_count := v_count + 1;
  end loop;

  -- Delete unmaterialized removed definitions. Historical references are
  -- retired instead, preserving the FK and the past snapshot.
  update public.task_subtask_definitions d set is_active=false
  where d.household_id=v_household and d.task_definition_id=p_task_definition_id
    and not (d.id=any(v_seen_ids))
    and exists(select 1 from public.task_subtask_instances i where i.household_id=d.household_id and i.source_definition_id=d.id);
  delete from public.task_subtask_definitions d
  where d.household_id=v_household and d.task_definition_id=p_task_definition_id
    and not (d.id=any(v_seen_ids))
    and not exists(select 1 from public.task_subtask_instances i where i.household_id=d.household_id and i.source_definition_id=d.id);
  update public.task_definitions set completion_mode=case when v_count>0 then 'subtasks' else 'whole' end
  where household_id=v_household and id=p_task_definition_id;
  v_result:=jsonb_build_object('ok',true,'task_definition_id',p_task_definition_id,'subtask_count',v_count);
  update private.mutation_receipts set result_type='task_definition',result_id=p_task_definition_id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end $$;
revoke all on function public.server_tx_replace_routine_subtasks(uuid,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_replace_routine_subtasks(uuid,uuid,uuid,jsonb) to service_role;

-- Disable/re-enable must also be valid for a rule whose effective start is in
-- the future. An inactive future rule needs no effective_to date; assigning
-- yesterday would violate the recurrence date-range constraint.
create or replace function public.server_tx_set_routine_definition_options(
  p_actor_id uuid,p_operation_id uuid,p_task_definition_id uuid,p_enabled boolean,p_include_in_routine_line boolean
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_household uuid; v_receipt record; v_hash text; v_result jsonb; v_today date := (now() at time zone 'Asia/Tokyo')::date;
begin
  v_hash:=encode(sha256(convert_to(jsonb_build_object('definition',p_task_definition_id,'enabled',p_enabled,'line',p_include_in_routine_line)::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash) values(p_actor_id,p_operation_id,'routine-definition-options-v1',v_hash) on conflict(actor_id,operation_id) do nothing;
  if not found then select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update; if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return v_receipt.result_payload; end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id; if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  update public.task_definitions set is_active=p_enabled,include_in_routine_line=p_include_in_routine_line where id=p_task_definition_id and household_id=v_household and task_kind in ('morning_chore','evening_chore');
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if not p_include_in_routine_line then
    delete from public.routine_checkin_session_items si using public.routine_checkin_sessions s, public.task_instances ti
    where si.household_id=v_household and si.session_id=s.id and si.task_instance_id=ti.id and ti.task_definition_id=p_task_definition_id and s.status='open' and s.scheduled_date>=v_today;
  end if;
  if not p_enabled then
    update public.recurrence_rules set active=false,
      effective_to=case when effective_from<=v_today then v_today-1 else effective_to end
    where household_id=v_household and task_definition_id=p_task_definition_id and active;
    delete from public.task_instances where household_id=v_household and task_definition_id=p_task_definition_id and scheduled_date>=v_today and status='todo';
  end if;
  v_result:=jsonb_build_object('ok',true); update private.mutation_receipts set result_payload=v_result,result_type='task_definition',result_id=p_task_definition_id where actor_id=p_actor_id and operation_id=p_operation_id; return v_result;
end $$;
revoke all on function public.server_tx_set_routine_definition_options(uuid,uuid,uuid,boolean,boolean) from public,anon,authenticated;
grant execute on function public.server_tx_set_routine_definition_options(uuid,uuid,uuid,boolean,boolean) to service_role;

-- New recurring task instances take a snapshot of the currently active
-- canonical definitions. Existing future/past materialized rows are not
-- changed by an edit, and completed History therefore remains immutable.
create or replace function private.materialize_recurrence_rule(
  p_household_id uuid,p_rule_id uuid,p_from_date date,p_to_date date
) returns void language plpgsql security invoker set search_path = '' as $$
declare
  v_rule public.recurrence_rules%rowtype; v_task public.task_definitions%rowtype;
  v_date date; v_logical_key text; v_planned_assignee uuid; v_pickup_assignee uuid;
  v_due_at timestamptz; v_instance_id uuid; v_subtask record;
begin
  select * into v_rule from public.recurrence_rules where id=p_rule_id and household_id=p_household_id;
  if not found or not v_rule.active then return; end if;
  select * into v_task from public.task_definitions where id=v_rule.task_definition_id and household_id=p_household_id;
  if not found or not v_task.is_active then return; end if;
  v_date:=p_from_date;
  while v_date<=p_to_date loop
    if extract(isodow from v_date)::smallint=v_rule.weekday and v_date>=v_rule.effective_from and (v_rule.effective_to is null or v_date<=v_rule.effective_to) then
      v_logical_key:='rec:'||v_rule.task_definition_id::text||':'||v_date::text||':'||v_rule.slot_key;
      if not exists(select 1 from public.task_instances where household_id=p_household_id and logical_occurrence_key=v_logical_key) then
        v_planned_assignee:=null;
        if v_rule.assignee_strategy='fixed' then v_planned_assignee:=v_rule.planned_assignee_id;
        elsif v_rule.assignee_strategy='dropoff_assignee' then
          select ti.planned_assignee_id into v_planned_assignee from public.task_instances ti join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id where ti.household_id=p_household_id and ti.scheduled_date=v_date and td.code='dropoff' limit 1;
        elsif v_rule.assignee_strategy='pickup_assignee' then
          select ti.planned_assignee_id into v_planned_assignee from public.task_instances ti join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id where ti.household_id=p_household_id and ti.scheduled_date=v_date and td.code='pickup' limit 1;
        elsif v_rule.assignee_strategy='nonpickup_adult' then
          select ti.planned_assignee_id into v_pickup_assignee from public.task_instances ti join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id where ti.household_id=p_household_id and ti.scheduled_date=v_date and td.code='pickup' limit 1;
          if v_pickup_assignee is not null then select user_id into v_planned_assignee from public.household_members where household_id=p_household_id and user_id<>v_pickup_assignee limit 1; end if;
        end if;
        v_due_at:=case when v_rule.scheduled_local_time is null then null else ((v_date::text||' '||v_rule.scheduled_local_time::text)::timestamp at time zone 'Asia/Tokyo') end;
        insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,logical_occurrence_key,origin,title,category,routine_phase,scheduled_date,due_at,planned_assignee_id,completion_mode,status,source,created_by)
        values(p_household_id,v_rule.task_definition_id,v_rule.id,v_logical_key,'recurring',v_task.title,v_task.category,v_task.routine_phase,v_date,v_due_at,v_planned_assignee,v_task.completion_mode,'todo','recurring',v_rule.created_by)
        returning id into v_instance_id;
        if v_task.completion_mode='subtasks' then
          for v_subtask in select * from public.task_subtask_definitions where household_id=p_household_id and task_definition_id=v_task.id and is_active order by sort_order,id loop
            insert into public.task_subtask_instances(household_id,task_instance_id,source_definition_id,title,required,sort_order)
            values(p_household_id,v_instance_id,v_subtask.id,v_subtask.title,v_subtask.required,v_subtask.sort_order);
          end loop;
        end if;
      end if;
    end if;
    v_date:=v_date+1;
  end loop;
end $$;
revoke all on function private.materialize_recurrence_rule(uuid,uuid,date,date) from public,anon,authenticated;
grant execute on function private.materialize_recurrence_rule(uuid,uuid,date,date) to service_role;

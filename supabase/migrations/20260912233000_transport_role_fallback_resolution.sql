-- F2 physical Android PWA remediation: role-derived recurrence fallback and
-- convergence when the corresponding transport occurrence is absent/cancelled.
--
-- Authority:
-- - Baseline §§6.6 / 28.6
-- - live same-day transport truth wins when available
-- - explicit fallback is used only when the role cannot resolve
-- - otherwise fail closed to unassigned
-- - protected/claimed/terminal occurrences are never silently overwritten

alter table public.recurrence_rules
  add column fallback_assignee_id uuid null;

alter table public.recurrence_rules
  add constraint recurrence_rules_household_id_fallback_assignee_id_fkey
  foreign key(household_id,fallback_assignee_id)
  references public.household_members(household_id,user_id);

alter table public.recurrence_rules
  add constraint recurrence_rules_fallback_strategy_check
  check (
    fallback_assignee_id is null
    or assignee_strategy in ('pickup_assignee','dropoff_assignee','nonpickup_adult')
  );

comment on column public.recurrence_rules.fallback_assignee_id is
  'Explicit household fallback used only when a role-derived assignee cannot resolve from live same-day transport truth.';

create or replace function private.fn_resolve_transport_role_assignee_v1(
  p_household_id uuid,
  p_date date,
  p_strategy text,
  p_fallback_assignee_id uuid
) returns uuid
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_transport_user uuid;
  v_other_user uuid;
  v_other_count int;
  v_code text;
begin
  if p_strategy not in ('pickup_assignee','dropoff_assignee','nonpickup_adult') then
    return null;
  end if;

  v_code := case when p_strategy='dropoff_assignee' then 'dropoff' else 'pickup' end;

  select ti.planned_assignee_id
    into v_transport_user
  from public.task_instances ti
  join public.task_definitions td
    on td.household_id=ti.household_id and td.id=ti.task_definition_id
  where ti.household_id=p_household_id
    and ti.scheduled_date=p_date
    and td.code=v_code
    and ti.status in ('todo','in_progress')
    and coalesce(ti.assignment_mode,'person')='person'
    and ti.planned_assignee_id is not null
  order by ti.updated_at desc,ti.id
  limit 1;

  if p_strategy in ('pickup_assignee','dropoff_assignee') then
    return coalesce(v_transport_user,p_fallback_assignee_id);
  end if;

  if v_transport_user is not null then
    select count(*),min(hm.user_id::text)::uuid
      into v_other_count,v_other_user
    from public.household_members hm
    where hm.household_id=p_household_id
      and hm.member_role='adult'
      and hm.user_id<>v_transport_user;

    if v_other_count=1 then
      return v_other_user;
    end if;
  end if;

  return p_fallback_assignee_id;
end;
$$;

revoke all on function private.fn_resolve_transport_role_assignee_v1(uuid,date,text,uuid)
  from public,anon,authenticated;
grant execute on function private.fn_resolve_transport_role_assignee_v1(uuid,date,text,uuid)
  to service_role;

-- Materialization uses live transport first, then explicit fallback.
create or replace function private.materialize_recurrence_rule(
  p_household_id uuid,
  p_rule_id uuid,
  p_from_date date,
  p_to_date date
)
returns void
language plpgsql
set search_path=''
as $$
declare
  v_rule public.recurrence_rules%rowtype;
  v_task public.task_definitions%rowtype;
  v_date date;
  v_logical_key text;
  v_planned_assignee uuid;
  v_due_at timestamptz;
  v_instance_id uuid;
  v_subtask record;
begin
  select * into v_rule
  from public.recurrence_rules
  where id=p_rule_id and household_id=p_household_id;
  if not found or not v_rule.active then return; end if;

  select * into v_task
  from public.task_definitions
  where id=v_rule.task_definition_id and household_id=p_household_id;
  if not found or not v_task.is_active then return; end if;

  v_date:=p_from_date;
  while v_date<=p_to_date loop
    if extract(isodow from v_date)::smallint=v_rule.weekday
       and v_date>=v_rule.effective_from
       and (v_rule.effective_to is null or v_date<=v_rule.effective_to) then
      v_logical_key:='rec:'||v_rule.task_definition_id::text||':'||v_date::text||':'||v_rule.slot_key;

      if not exists(
        select 1 from public.task_instances
        where household_id=p_household_id and logical_occurrence_key=v_logical_key
      ) then
        v_planned_assignee:=null;

        if v_rule.assignee_strategy='fixed' then
          v_planned_assignee:=v_rule.planned_assignee_id;
        elsif v_rule.assignee_strategy in ('dropoff_assignee','pickup_assignee','nonpickup_adult') then
          v_planned_assignee:=private.fn_resolve_transport_role_assignee_v1(
            p_household_id,v_date,v_rule.assignee_strategy,v_rule.fallback_assignee_id
          );
        end if;

        v_due_at:=case
          when v_rule.scheduled_local_time is null then null
          else ((v_date::text||' '||v_rule.scheduled_local_time::text)::timestamp at time zone 'Asia/Tokyo')
        end;

        insert into public.task_instances(
          household_id,task_definition_id,recurrence_rule_id,logical_occurrence_key,
          origin,title,category,routine_phase,scheduled_date,due_at,
          planned_assignee_id,completion_mode,status,source,created_by
        ) values(
          p_household_id,v_rule.task_definition_id,v_rule.id,v_logical_key,
          'recurring',v_task.title,v_task.category,v_task.routine_phase,v_date,v_due_at,
          v_planned_assignee,v_task.completion_mode,'todo','recurring',v_rule.created_by
        )
        returning id into v_instance_id;

        if v_task.completion_mode='subtasks' then
          for v_subtask in
            select *
            from public.task_subtask_definitions
            where household_id=p_household_id
              and task_definition_id=v_task.id
              and is_active
            order by sort_order,id
          loop
            insert into public.task_subtask_instances(
              household_id,task_instance_id,source_definition_id,title,required,sort_order
            ) values(
              p_household_id,v_instance_id,v_subtask.id,v_subtask.title,
              v_subtask.required,v_subtask.sort_order
            );
          end loop;
        end if;
      end if;
    end if;
    v_date:=v_date+1;
  end loop;
end;
$$;

-- Reconcile one transport leg/date after the leg becomes absent/cancelled/unassigned
-- (or is restored from such a state). Explicit one-off A->B agreements remain
-- handled by the request transition reconciliation so request-scoped audit stays intact.
create or replace function private.fn_reconcile_transport_role_date_v1(
  p_household_id uuid,
  p_date date,
  p_leg text,
  p_source text,
  p_anchor_task_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_dep record;
  v_desired_user uuid;
  v_desired_actor_ref uuid;
  v_desired_mode text;
  v_previous_user uuid;
  v_previous_actor_ref uuid;
  v_previous_mode text;
  v_previous_revision bigint;
  v_new_revision bigint;
  v_updated int:=0;
  v_items jsonb:='[]'::jsonb;
begin
  if p_leg not in ('pickup','dropoff') then
    raise exception 'INVALID_INPUT';
  end if;

  for v_dep in
    select ti.*,rr.assignee_strategy,rr.fallback_assignee_id
    from public.task_instances ti
    join public.recurrence_rules rr
      on rr.household_id=ti.household_id and rr.id=ti.recurrence_rule_id
    where ti.household_id=p_household_id
      and ti.scheduled_date=p_date
      and ti.status in ('todo','in_progress')
      and coalesce(ti.assignment_source,'legacy_snapshot')='legacy_snapshot'
      and ti.active_claimant_actor_ref_id is null
      and not (coalesce(ti.source_context,'{}'::jsonb) ? 'transport_occurrence_override')
      and (
        (p_leg='pickup' and rr.assignee_strategy in ('pickup_assignee','nonpickup_adult'))
        or
        (p_leg='dropoff' and rr.assignee_strategy='dropoff_assignee')
      )
      and not exists(
        select 1
        from public.task_events e
        where e.household_id=ti.household_id
          and e.task_instance_id=ti.id
          and e.event_type in ('assignment_agreed','reassigned_once','cancelled')
      )
    order by ti.due_at nulls last,ti.id
    for update of ti
  loop
    v_desired_user:=private.fn_resolve_transport_role_assignee_v1(
      p_household_id,p_date,v_dep.assignee_strategy,v_dep.fallback_assignee_id
    );
    v_desired_actor_ref:=null;

    if v_desired_user is not null then
      select dar.id
        into v_desired_actor_ref
      from public.domain_actor_refs dar
      where dar.household_id=p_household_id
        and dar.actor_kind='real_user'
        and dar.real_user_id=v_desired_user
        and dar.test_context_id is null
      order by dar.id
      limit 1;

      if v_desired_actor_ref is null then
        v_desired_user:=null;
      end if;
    end if;

    v_desired_mode:=case when v_desired_user is null then 'unassigned' else 'person' end;

    if v_dep.planned_assignee_id is not distinct from v_desired_user
       and v_dep.planned_assignee_actor_ref_id is not distinct from v_desired_actor_ref
       and coalesce(v_dep.assignment_mode,v_desired_mode)=v_desired_mode then
      continue;
    end if;

    v_previous_user:=v_dep.planned_assignee_id;
    v_previous_actor_ref:=v_dep.planned_assignee_actor_ref_id;
    v_previous_mode:=coalesce(v_dep.assignment_mode,
      case when v_dep.planned_assignee_id is null then 'unassigned' else 'person' end);
    v_previous_revision:=v_dep.revision;

    update public.task_instances
    set planned_assignee_id=v_desired_user,
        planned_assignee_actor_ref_id=v_desired_actor_ref,
        assignment_mode=v_desired_mode,
        assignment_source='legacy_snapshot',
        revision=revision+1
    where household_id=p_household_id and id=v_dep.id
    returning revision into v_new_revision;

    insert into public.task_events(
      household_id,task_instance_id,actor_id,actor_ref_id,test_context_id,
      event_type,payload,source,idempotency_key
    ) values(
      p_household_id,v_dep.id,null,null,null,
      'edited',
      jsonb_build_object(
        'reason','transport_role_fallback_reconcile',
        'anchor_task_id',p_anchor_task_id,
        'transport_leg',p_leg,
        'assignee_strategy',v_dep.assignee_strategy,
        'fallback_assignee_user_id',v_dep.fallback_assignee_id,
        'previous_assignment_mode',v_previous_mode,
        'previous_assignee_user_id',v_previous_user,
        'previous_assignee_actor_ref_id',v_previous_actor_ref,
        'assignment_mode',v_desired_mode,
        'assignee_user_id',v_desired_user,
        'assignee_actor_ref_id',v_desired_actor_ref,
        'previous_revision',v_previous_revision,
        'revision',v_new_revision
      ),
      coalesce(nullif(p_source,''),'transport_role_reconcile'),
      'transport-role-reconcile:'||coalesce(p_anchor_task_id::text,'none')||':'||v_dep.id::text||':'||v_new_revision::text
    );

    v_updated:=v_updated+1;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'task_id',v_dep.id,
      'strategy',v_dep.assignee_strategy,
      'assignee_user_id',v_desired_user,
      'revision',v_new_revision
    ));
  end loop;

  return jsonb_build_object('updated',v_updated,'items',v_items);
end;
$$;

revoke all on function private.fn_reconcile_transport_role_date_v1(uuid,date,text,text,uuid)
  from public,anon,authenticated;
grant execute on function private.fn_reconcile_transport_role_date_v1(uuid,date,text,text,uuid)
  to service_role;

create or replace function private.fn_transport_role_anchor_reconcile_trigger_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $transport_trigger$
declare
  v_row public.task_instances%rowtype;
  v_code text;
  v_should_reconcile boolean:=false;
begin
  if tg_op='DELETE' then
    v_row:=old;
  else
    v_row:=new;
  end if;

  select td.code into v_code
  from public.task_definitions td
  where td.household_id=v_row.household_id and td.id=v_row.task_definition_id;

  if v_code not in ('pickup','dropoff') then
    if tg_op='DELETE' then return old; end if;
    return new;
  end if;

  if tg_op='DELETE' then
    v_should_reconcile:=true;
  elsif tg_op='UPDATE' then
    -- Do not duplicate the normal open-assigned A->B request path; that path
    -- already writes request-scoped dependency audit. Reconcile when the leg
    -- becomes unresolved/cancelled, or when it is restored from such a state.
    v_should_reconcile:=
      new.status not in ('todo','in_progress')
      or new.planned_assignee_id is null
      or old.status not in ('todo','in_progress')
      or old.planned_assignee_id is null;
  end if;

  if v_should_reconcile then
    perform private.fn_reconcile_transport_role_date_v1(
      v_row.household_id,
      v_row.scheduled_date,
      v_code,
      'transport_anchor_state',
      v_row.id
    );
  end if;

  if tg_op='DELETE' then return old; end if;
  return new;
end;
$transport_trigger$;

revoke all on function private.fn_transport_role_anchor_reconcile_trigger_v1()
  from public,anon,authenticated;

drop trigger if exists task_transport_role_reconcile_update on public.task_instances;
create trigger task_transport_role_reconcile_update
after update of status,planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode
on public.task_instances
for each row execute function private.fn_transport_role_anchor_reconcile_trigger_v1();

drop trigger if exists task_transport_role_reconcile_delete on public.task_instances;
create trigger task_transport_role_reconcile_delete
after delete on public.task_instances
for each row execute function private.fn_transport_role_anchor_reconcile_trigger_v1();

-- Keep the existing API signature. For role-derived strategies the existing
-- p_planned_assignee_user_id parameter now means explicit fallback; for fixed
-- it remains the fixed assignee. Existing callers that omit it are unchanged.
create or replace function public.server_tx_change_recurrence(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_definition_id uuid,
  p_weekday integer,
  p_slot_key text,
  p_assignee_strategy text,
  p_planned_assignee_user_id uuid,
  p_scheduled_local_time time without time zone,
  p_conflict_window_minutes integer,
  p_effective_from date
)
returns jsonb
language plpgsql
set search_path=''
as $$
declare
  v_today date:=(now() at time zone 'Asia/Tokyo')::date;
  v_slot_key text:=coalesce(nullif(btrim(p_slot_key),''),'default');
  v_conflict_window int:=coalesce(p_conflict_window_minutes,60);
  v_effective_from date:=coalesce(p_effective_from,v_today);
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_task public.task_definitions%rowtype;
  v_existing_rule public.recurrence_rules%rowtype;
  v_rule_id uuid;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null
     or p_task_definition_id is null or p_weekday is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_weekday not between 1 and 7 then raise exception 'INVALID_INPUT'; end if;
  if p_assignee_strategy is null
     or p_assignee_strategy not in ('fixed','dropoff_assignee','pickup_assignee','nonpickup_adult','unassigned') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_assignee_strategy='fixed' and p_planned_assignee_user_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_assignee_strategy='unassigned' and p_planned_assignee_user_id is not null then
    raise exception 'INVALID_INPUT';
  end if;
  if v_conflict_window<0 or v_conflict_window>720 then raise exception 'INVALID_INPUT'; end if;
  if v_effective_from<v_today then raise exception 'INVALID_INPUT'; end if;

  v_request_hash:=encode(sha256(convert_to(
    'change-recurrence|'||p_task_definition_id::text||'|'||p_weekday::text||'|'||v_slot_key
    ||'|'||p_assignee_strategy||'|'||coalesce(p_planned_assignee_user_id::text,'')
    ||'|'||coalesce(p_scheduled_local_time::text,'')||'|'||v_conflict_window::text
    ||'|'||v_effective_from::text,'UTF8')),'hex');

  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
    values(p_actor_id,p_operation_id,'change-recurrence',v_request_hash)
    on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id=p_actor_id and operation_id=p_operation_id
    for update;

    if found then
      if v_receipt.request_hash<>v_request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id=p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select * into v_task
  from public.task_definitions
  where household_id=v_household_id and id=p_task_definition_id;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;

  if v_task.code in ('dropoff','pickup')
     and p_assignee_strategy in ('dropoff_assignee','pickup_assignee','nonpickup_adult') then
    raise exception 'INVALID_INPUT';
  end if;

  if p_planned_assignee_user_id is not null and not exists(
    select 1 from public.household_members
    where household_id=v_household_id and user_id=p_planned_assignee_user_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  select * into v_existing_rule
  from public.recurrence_rules
  where household_id=v_household_id
    and task_definition_id=p_task_definition_id
    and weekday=p_weekday and slot_key=v_slot_key and active
  order by version desc
  limit 1;

  if found then
    update public.recurrence_rules
    set active=false,
        effective_to=greatest(v_today-1,v_existing_rule.effective_from)
    where id=v_existing_rule.id;

    delete from public.task_instances
    where household_id=v_household_id
      and recurrence_rule_id=v_existing_rule.id
      and scheduled_date>=v_today
      and status='todo';
  end if;

  begin
    insert into public.recurrence_rules(
      household_id,task_definition_id,weekday,slot_key,
      assignee_strategy,planned_assignee_id,fallback_assignee_id,
      scheduled_local_time,conflict_window_minutes,
      effective_from,active,version,supersedes_rule_id,created_by
    ) values(
      v_household_id,p_task_definition_id,p_weekday,v_slot_key,
      p_assignee_strategy,
      case when p_assignee_strategy='fixed' then p_planned_assignee_user_id else null end,
      case when p_assignee_strategy in ('dropoff_assignee','pickup_assignee','nonpickup_adult')
           then p_planned_assignee_user_id else null end,
      p_scheduled_local_time,v_conflict_window,
      v_effective_from,true,coalesce(v_existing_rule.version,0)+1,v_existing_rule.id,p_actor_id
    ) returning id into v_rule_id;
  exception
    when exclusion_violation then raise exception 'RECURRENCE_OVERLAP';
    when deadlock_detected then raise exception 'RECURRENCE_OVERLAP';
  end;

  perform private.materialize_recurrence_rule(v_household_id,v_rule_id,v_today,v_today+14);

  v_result:=jsonb_build_object(
    'rule_id',v_rule_id,
    'task_definition_id',p_task_definition_id,
    'weekday',p_weekday,
    'slot_key',v_slot_key,
    'assignee_strategy',p_assignee_strategy,
    'fallback_assignee_id',
      case when p_assignee_strategy in ('dropoff_assignee','pickup_assignee','nonpickup_adult')
           then p_planned_assignee_user_id else null end,
    'effective_from',v_effective_from
  );

  update private.mutation_receipts
  set result_type='recurrence_rule',result_id=v_rule_id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;

  return v_result;
end;
$$;

-- Deterministic one-time fallback seed:
-- for direct pickup/dropoff role rules, use the most recent non-cancelled,
-- non-null assignee for the same household + weekday + transport leg.
-- This is evidence-based migration only; if no evidence exists, fallback stays null.
with candidates as (
  select rr.id,
    (
      select ti.planned_assignee_id
      from public.task_instances ti
      join public.task_definitions td
        on td.household_id=ti.household_id and td.id=ti.task_definition_id
      where ti.household_id=rr.household_id
        and td.code=case rr.assignee_strategy
          when 'pickup_assignee' then 'pickup'
          when 'dropoff_assignee' then 'dropoff'
          else null end
        and extract(isodow from ti.scheduled_date)::int=rr.weekday
        and ti.scheduled_date<(now() at time zone 'Asia/Tokyo')::date
        and ti.status<>'cancelled'
        and ti.planned_assignee_id is not null
      order by ti.scheduled_date desc,ti.updated_at desc,ti.id
      limit 1
    ) as fallback_user
  from public.recurrence_rules rr
  where rr.active
    and rr.fallback_assignee_id is null
    and rr.assignee_strategy in ('pickup_assignee','dropoff_assignee')
)
update public.recurrence_rules rr
set fallback_assignee_id=c.fallback_user
from candidates c
where rr.id=c.id and c.fallback_user is not null;

-- Reconcile existing open role-derived snapshots now that fallback exists.
do $$
declare
  x record;
begin
  for x in
    select distinct ti.household_id,ti.scheduled_date
    from public.task_instances ti
    join public.recurrence_rules rr
      on rr.household_id=ti.household_id and rr.id=ti.recurrence_rule_id
    where ti.status in ('todo','in_progress')
      and rr.assignee_strategy in ('pickup_assignee','dropoff_assignee','nonpickup_adult')
  loop
    perform private.fn_reconcile_transport_role_date_v1(
      x.household_id,x.scheduled_date,'pickup','migration_role_fallback',null
    );
    perform private.fn_reconcile_transport_role_date_v1(
      x.household_id,x.scheduled_date,'dropoff','migration_role_fallback',null
    );
  end loop;
end;
$$;

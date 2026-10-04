-- Two more ways to decide who does a routine task (owner rules, 2026-10-04):
--
--   next_day_nondropoff_adult  "前の晩：次の日に送らない人" -- the nursery preparation
--                              (bags, clothes) moves from the morning to the evening
--                              before, done by the adult who does NOT take the children
--                              the next day. Only created before a nursery day, once that
--                              day's dropoff exists; re-resolved when that dropoff changes.
--   anyone_adult               "先に家を出る人" and other first-come tasks: shown as
--                              誰でもOK (assignment_mode 'anyone'), claimable as usual.
--
-- The daily batch now materializes transport rules first, so the role-based tasks of
-- the same run find their transport rows.

alter table public.recurrence_rules drop constraint if exists recurrence_rules_assignee_strategy_check;
alter table public.recurrence_rules add constraint recurrence_rules_assignee_strategy_check
  check (assignee_strategy = any (array['fixed','dropoff_assignee','pickup_assignee','nonpickup_adult',
    'previous_evening_assignee','unassigned','next_day_nondropoff_adult','anyone_adult']));

create or replace function private.fn_resolve_next_day_nondropoff_v1(
  p_household_id uuid,
  p_date date
) returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $next_day$
declare
  v_dropoff uuid;
  v_other uuid;
  v_count int;
begin
  if p_household_id is null or p_date is null then
    return jsonb_build_object('mode','unassigned','user_id',null);
  end if;
  select ti.planned_assignee_id into v_dropoff
  from public.task_instances ti
  join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id
  where ti.household_id=p_household_id and ti.scheduled_date=p_date+1
    and td.code='dropoff' and ti.test_context_id is null
    and ti.status in ('todo','in_progress','completed')
    and ti.planned_assignee_id is not null
  order by ti.updated_at desc, ti.id
  limit 1;
  if v_dropoff is null then
    return jsonb_build_object('mode','unassigned','user_id',null);
  end if;
  select count(*), min(hm.user_id::text)::uuid into v_count, v_other
  from public.household_members hm
  where hm.household_id=p_household_id and hm.member_role='adult' and hm.user_id<>v_dropoff;
  if v_count=1 then
    return jsonb_build_object('mode','person','user_id',v_other);
  end if;
  return jsonb_build_object('mode','unassigned','user_id',null);
end;
$next_day$;
revoke all on function private.fn_resolve_next_day_nondropoff_v1(uuid,date) from public,anon,authenticated;
grant execute on function private.fn_resolve_next_day_nondropoff_v1(uuid,date) to service_role;

CREATE OR REPLACE FUNCTION private.materialize_recurrence_rule(p_household_id uuid, p_rule_id uuid, p_from_date date, p_to_date date)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_rule public.recurrence_rules%rowtype;
  v_task public.task_definitions%rowtype;
  v_date date;
  v_logical_key text;
  v_assignment jsonb;
  v_assignment_mode text;
  v_planned_assignee uuid;
  v_planned_actor_ref uuid;
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

      -- Codmon is a nursery-business-day obligation. Weekend/holiday rows
      -- would be noise and could generate false deadline reminders.
      if v_task.code like 'codmon_%' and private.fn_is_nonworkday(v_date) then
        v_date:=v_date+1;
        continue;
      end if;

      -- "Yesterday's responsible person" is only knowable once that yesterday
      -- has actually happened. Never pre-materialize a future owner.
      if v_rule.assignee_strategy='previous_evening_assignee'
         and v_date>p_from_date then
        v_date:=v_date+1;
        continue;
      end if;

      -- "The one who does not take the children tomorrow" (evening preparation):
      -- only before a nursery day, and only once tomorrow's dropoff exists. The
      -- daily batch materializes transport first and moves the window a day at a
      -- time, so a skipped evening is created on the next run.
      if v_rule.assignee_strategy='next_day_nondropoff_adult' then
        if private.fn_is_nonworkday(v_date+1)
           or not exists(
             select 1 from public.task_instances ti
             join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id
             where ti.household_id=p_household_id and ti.scheduled_date=v_date+1
               and td.code='dropoff' and ti.test_context_id is null
           ) then
          v_date:=v_date+1;
          continue;
        end if;
      end if;

      v_logical_key:='rec:'||v_rule.task_definition_id::text||':'||v_date::text||':'||v_rule.slot_key;

      if not exists(
        select 1 from public.task_instances
        where household_id=p_household_id and logical_occurrence_key=v_logical_key
      ) then
        v_planned_assignee:=null;
        v_planned_actor_ref:=null;
        v_assignment_mode:='unassigned';

        if v_rule.assignee_strategy='fixed' then
          v_planned_assignee:=v_rule.planned_assignee_id;
          v_assignment_mode:=case when v_planned_assignee is null then 'unassigned' else 'person' end;
        elsif v_rule.assignee_strategy in ('dropoff_assignee','pickup_assignee','nonpickup_adult') then
          v_assignment:=private.fn_resolve_transport_role_assignment_v2(
            p_household_id,v_date,v_rule.assignee_strategy,v_rule.fallback_assignee_id
          );
          v_assignment_mode:=coalesce(v_assignment->>'mode','unassigned');
          v_planned_assignee:=nullif(v_assignment->>'user_id','')::uuid;
        elsif v_rule.assignee_strategy='next_day_nondropoff_adult' then
          v_assignment:=private.fn_resolve_next_day_nondropoff_v1(p_household_id,v_date);
          v_assignment_mode:=coalesce(v_assignment->>'mode','unassigned');
          v_planned_assignee:=nullif(v_assignment->>'user_id','')::uuid;
        elsif v_rule.assignee_strategy='anyone_adult' then
          v_assignment_mode:='anyone';
        elsif v_rule.assignee_strategy='previous_evening_assignee' then
          v_assignment:=private.fn_resolve_previous_evening_assignee_v1(
            p_household_id,v_date
          );
          v_assignment_mode:=coalesce(v_assignment->>'mode','unassigned');
          v_planned_assignee:=nullif(v_assignment->>'user_id','')::uuid;
        end if;

        if v_assignment_mode='person' and v_planned_assignee is not null then
          select dar.id into v_planned_actor_ref
          from public.domain_actor_refs dar
          where dar.household_id=p_household_id
            and dar.actor_kind='real_user'
            and dar.real_user_id=v_planned_assignee
            and dar.test_context_id is null
          order by dar.id
          limit 1;
          if v_planned_actor_ref is null then
            v_assignment_mode:='unassigned';
            v_planned_assignee:=null;
          end if;
        end if;

        v_due_at:=case
          when v_rule.scheduled_local_time is null then null
          else ((v_date::text||' '||v_rule.scheduled_local_time::text)::timestamp at time zone 'Asia/Tokyo')
        end;

        insert into public.task_instances(
          household_id,task_definition_id,recurrence_rule_id,logical_occurrence_key,
          origin,title,category,routine_phase,scheduled_date,due_at,
          planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,
          completion_mode,status,source,created_by
        ) values(
          p_household_id,v_rule.task_definition_id,v_rule.id,v_logical_key,
          'recurring',v_task.title,v_task.category,v_task.routine_phase,v_date,v_due_at,
          v_planned_assignee,v_planned_actor_ref,v_assignment_mode,
          v_task.completion_mode,'todo','recurring',v_rule.created_by
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
$function$;

CREATE OR REPLACE FUNCTION private.fn_reconcile_transport_role_date_v1(p_household_id uuid, p_date date, p_leg text, p_source text, p_anchor_task_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_dep record;
  v_assignment jsonb;
  v_desired_user uuid;
  v_desired_actor_ref uuid;
  v_desired_mode text;
  v_audit_actor_ref uuid;
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

  v_audit_actor_ref:=private.fn_household_system_actor_ref_v1(p_household_id);

  for v_dep in
    select ti.*,rr.assignee_strategy,rr.fallback_assignee_id
    from public.task_instances ti
    join public.recurrence_rules rr
      on rr.household_id=ti.household_id and rr.id=ti.recurrence_rule_id
    where ti.household_id=p_household_id
      and (
        ti.scheduled_date=p_date
        -- The evening before: preparation by whoever does not take the children.
        or (p_leg='dropoff' and ti.scheduled_date=p_date-1 and rr.assignee_strategy='next_day_nondropoff_adult')
      )
      and ti.test_context_id is null
      and ti.status in ('todo','in_progress')
      and coalesce(ti.assignment_source,'legacy_snapshot')='legacy_snapshot'
      and ti.active_claimant_actor_ref_id is null
      and not (coalesce(ti.source_context,'{}'::jsonb) ? 'transport_occurrence_override')
      and (
        (p_leg='pickup' and rr.assignee_strategy in ('pickup_assignee','nonpickup_adult'))
        or
        (p_leg='dropoff' and rr.assignee_strategy in ('dropoff_assignee','next_day_nondropoff_adult'))
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
    v_assignment:=case when v_dep.assignee_strategy='next_day_nondropoff_adult'
      then private.fn_resolve_next_day_nondropoff_v1(p_household_id,v_dep.scheduled_date)
      else private.fn_resolve_transport_role_assignment_v2(
        p_household_id,p_date,v_dep.assignee_strategy,v_dep.fallback_assignee_id
      ) end;
    v_desired_mode:=coalesce(v_assignment->>'mode','unassigned');
    v_desired_user:=nullif(v_assignment->>'user_id','')::uuid;
    v_desired_actor_ref:=null;

    if v_desired_mode='person' and v_desired_user is not null then
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
        v_desired_mode:='unassigned';
      end if;
    else
      v_desired_user:=null;
    end if;

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
        active_claimant_actor_ref_id=null,
        claimed_at=null,
        revision=revision+1
    where household_id=p_household_id and id=v_dep.id
    returning revision into v_new_revision;

    insert into public.task_events(
      household_id,task_instance_id,actor_id,actor_ref_id,test_context_id,
      event_type,payload,source,idempotency_key
    ) values(
      p_household_id,v_dep.id,null,v_audit_actor_ref,null,
      'edited',
      jsonb_build_object(
        'reason',case when v_desired_mode='anyone'
          then 'transport_role_weekend_anyone_reconcile'
          else 'transport_role_fallback_reconcile'
        end,
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
      'transport-role-weekend:'||coalesce(p_anchor_task_id::text,'none')||':'||v_dep.id::text||':'||v_new_revision::text
    );

    v_updated:=v_updated+1;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'task_id',v_dep.id,
      'strategy',v_dep.assignee_strategy,
      'assignment_mode',v_desired_mode,
      'assignee_user_id',v_desired_user,
      'revision',v_new_revision
    ));
  end loop;

  return jsonb_build_object('updated',v_updated,'items',v_items);
end;
$function$;

CREATE OR REPLACE FUNCTION public.server_tx_materialize_recurring_batch(p_today date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_rule record;
  v_materialized int := 0;
  v_failed int := 0;
begin
  if p_today is null then
    raise exception 'INVALID_INPUT';
  end if;

  insert into private.worker_run_receipts (worker_kind, logical_slot_key)
  values ('materialize-recurring', p_today::text)
  on conflict (worker_kind, logical_slot_key) do nothing;

  if not found then
    -- Already ran (or is running) for this Asia/Tokyo day — cron retry
    -- within the same day is a no-op, matching every other scheduled-worker
    -- idempotency guard in this codebase.
    return jsonb_build_object('already_ran', true, 'materialized', 0, 'failed', 0);
  end if;

  for v_rule in
    select rr.id, rr.household_id
    from public.recurrence_rules rr
    where rr.active = true
      and rr.effective_from <= p_today
      and (rr.effective_to is null or rr.effective_to >= p_today)
    -- Transport first: role-based tasks (and the evening before) read that day's
    -- dropoff/pickup assignee from the rows created here.
    order by (rr.transport_leg is null), rr.id
  loop
    begin
      perform private.materialize_recurrence_rule(
        v_rule.household_id, v_rule.id, p_today, p_today + 14
      );
      v_materialized := v_materialized + 1;
    exception when others then
      -- One bad rule must never abort the whole daily batch for every other
      -- household — log via the return payload (the Edge Function logs
      -- server-side) and continue.
      v_failed := v_failed + 1;
    end;
  end loop;

  update private.worker_run_receipts
  set completed_at = now(),
      result = jsonb_build_object('materialized', v_materialized, 'failed', v_failed)
  where worker_kind = 'materialize-recurring' and logical_slot_key = p_today::text;

  return jsonb_build_object('already_ran', false, 'materialized', v_materialized, 'failed', v_failed);
end;
$function$;

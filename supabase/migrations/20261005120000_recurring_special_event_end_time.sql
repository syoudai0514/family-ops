-- A recurring special event can have an end time (owner 2026-10-05: 将生のプール is
-- Saturday 14:00-15:00). Until now a recurring task only had a start, so Google
-- Calendar showed it as an all-day "14:00 将生のプール". The definition's
-- default_duration_minutes now gives the end for special (calendar) definitions only;
-- chores keep no end. Same function as 20261004120000 otherwise.

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
  v_ends_at timestamptz;
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

        -- A recurring calendar event (special) with a known length gets its end time,
        -- so Google Calendar shows "14:00-15:00" instead of an all-day event.
        v_ends_at:=case
          when v_due_at is not null and v_task.calendar_visibility='special'
               and v_task.default_duration_minutes is not null
            then v_due_at+make_interval(mins=>v_task.default_duration_minutes)
          else null
        end;

        insert into public.task_instances(
          household_id,task_definition_id,recurrence_rule_id,logical_occurrence_key,
          origin,title,category,routine_phase,scheduled_date,due_at,calendar_ends_at,
          planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,
          completion_mode,status,source,created_by
        ) values(
          p_household_id,v_rule.task_definition_id,v_rule.id,v_logical_key,
          'recurring',v_task.title,v_task.category,v_task.routine_phase,v_date,v_due_at,v_ends_at,
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

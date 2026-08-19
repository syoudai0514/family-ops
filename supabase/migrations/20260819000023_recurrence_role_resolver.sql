-- WP3 (Recurrence engine): role-based assignee strategy resolver.
--
-- WP1's private.materialize_recurrence_rule (migration
-- 20260819000012_evening_routine_setup.sql) deliberately left
-- 'dropoff_assignee'/'pickup_assignee'/'nonpickup_adult' resolving to
-- planned_assignee_id = null, with an explicit code comment punting the
-- real resolver to WP3 ("Recurrence engine") per
-- docs/design/v6/10_WORK_PACKAGES.md. This migration is that resolver. It
-- amends the existing function in place (same signature, same iteration/
-- upsert-by-logical-key structure) rather than introducing a parallel
-- materializer, so every existing caller (configure-evening-routines,
-- configure-dropoff-pickup) and the new change-recurrence endpoint all gain
-- real role resolution for free.
--
-- Algorithm (docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #3 "Recurring
-- materialization", 08_RECURRING_TASKS_AND_RULES.md #4 "Assignee
-- strategy"):
--   - dropoff_assignee -> that same calendar date's dropoff task_instance's
--     planned_assignee_id
--   - pickup_assignee  -> that same calendar date's pickup task_instance's
--     planned_assignee_id
--   - nonpickup_adult  -> the OTHER household adult relative to that same
--     date's pickup task_instance's planned_assignee_id
-- The same-day dropoff/pickup task_instance is identified via the
-- canonical task_definitions.code ('dropoff'/'pickup', bootstrapped once
-- per household by private.bootstrap_canonical_task_definitions in
-- migration 20260819000013) rather than category text, matching how
-- 20260819000018_dropoff_pickup_setup.sql already identifies these two
-- rows (`where code = v_task_code`).
--
-- Implementation decision (not pinned down verbatim by the design docs,
-- flagged per house style): when the same-day dropoff/pickup instance does
-- not exist yet (household hasn't configured dropoff/pickup for that
-- weekday, or that rule hasn't been materialized for this date yet), the
-- resolver leaves planned_assignee_id null rather than guessing — this is
-- the literal fallback #3 already documents ("unresolved role never
-- guesses a user; it stays null and raises setup warning") and matches #4's
-- resolution order note ("if role cannot resolve, leave unassigned").
-- Surfacing an actual "setup warning" to the UI is a WP4/presentation
-- concern, not a WP3 data-layer one; the null planned_assignee_id itself is
-- the signal.

create or replace function private.materialize_recurrence_rule(
  p_household_id uuid,
  p_rule_id uuid,
  p_from_date date,
  p_to_date date
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_rule public.recurrence_rules%rowtype;
  v_task public.task_definitions%rowtype;
  v_date date;
  v_logical_key text;
  v_planned_assignee uuid;
  v_pickup_assignee uuid;
  v_due_at timestamptz;
begin
  select * into v_rule from public.recurrence_rules
  where id = p_rule_id and household_id = p_household_id;
  if not found or not v_rule.active then
    return;
  end if;

  select * into v_task from public.task_definitions
  where id = v_rule.task_definition_id and household_id = p_household_id;
  if not found then
    return;
  end if;

  v_date := p_from_date;
  while v_date <= p_to_date loop
    if extract(isodow from v_date)::smallint = v_rule.weekday
      and v_date >= v_rule.effective_from
      and (v_rule.effective_to is null or v_date <= v_rule.effective_to)
    then
      v_logical_key := 'rec:' || v_rule.task_definition_id::text || ':' || v_date::text || ':' || v_rule.slot_key;

      if not exists (
        select 1 from public.task_instances
        where household_id = p_household_id and logical_occurrence_key = v_logical_key
      ) then
        v_planned_assignee := null;

        if v_rule.assignee_strategy = 'fixed' then
          v_planned_assignee := v_rule.planned_assignee_id;
        elsif v_rule.assignee_strategy = 'dropoff_assignee' then
          select ti.planned_assignee_id into v_planned_assignee
          from public.task_instances ti
          join public.task_definitions td
            on td.household_id = ti.household_id and td.id = ti.task_definition_id
          where ti.household_id = p_household_id and ti.scheduled_date = v_date
            and td.code = 'dropoff'
          limit 1;
        elsif v_rule.assignee_strategy = 'pickup_assignee' then
          select ti.planned_assignee_id into v_planned_assignee
          from public.task_instances ti
          join public.task_definitions td
            on td.household_id = ti.household_id and td.id = ti.task_definition_id
          where ti.household_id = p_household_id and ti.scheduled_date = v_date
            and td.code = 'pickup'
          limit 1;
        elsif v_rule.assignee_strategy = 'nonpickup_adult' then
          v_pickup_assignee := null;

          select ti.planned_assignee_id into v_pickup_assignee
          from public.task_instances ti
          join public.task_definitions td
            on td.household_id = ti.household_id and td.id = ti.task_definition_id
          where ti.household_id = p_household_id and ti.scheduled_date = v_date
            and td.code = 'pickup'
          limit 1;

          if v_pickup_assignee is not null then
            select hm.user_id into v_planned_assignee
            from public.household_members hm
            where hm.household_id = p_household_id and hm.user_id <> v_pickup_assignee
            limit 1;
          end if;
        end if;
        -- 'unassigned' (and any unresolved role above) falls through with
        -- v_planned_assignee left null.

        v_due_at := null;
        if v_rule.scheduled_local_time is not null then
          v_due_at := ((v_date::text || ' ' || v_rule.scheduled_local_time::text)::timestamp
            at time zone 'Asia/Tokyo');
        end if;

        insert into public.task_instances (
          household_id, task_definition_id, recurrence_rule_id, logical_occurrence_key,
          origin, title, category, routine_phase, scheduled_date, due_at,
          planned_assignee_id, completion_mode, status, source, created_by
        ) values (
          p_household_id, v_rule.task_definition_id, v_rule.id, v_logical_key,
          'recurring', v_task.title, v_task.category, v_task.routine_phase, v_date, v_due_at,
          v_planned_assignee, v_task.completion_mode, 'todo', 'recurring', v_rule.created_by
        );
      end if;
    end if;
    v_date := v_date + 1;
  end loop;
end;
$$;

revoke all on function private.materialize_recurrence_rule(uuid, uuid, date, date) from public;
revoke all on function private.materialize_recurrence_rule(uuid, uuid, date, date) from anon;
revoke all on function private.materialize_recurrence_rule(uuid, uuid, date, date) from authenticated;
grant execute on function private.materialize_recurrence_rule(uuid, uuid, date, date) to service_role;

-- Replace the temporary cold-medicine routines with the household's regular
-- garbage schedule. Forward-only: historical completed task snapshots stay as-is.
-- This migration was still pending in production when amended; the cleanup
-- detaches current/future routine-session items before removing their todo tasks.

do $$
declare
  v_household record;
  v_household_id uuid;
  v_actor_id uuid;
  v_def_id uuid;
  v_rule_id uuid;
  v_weekday int;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
begin
  for v_household in
    select h.id,
      (select hm.user_id
         from public.household_members hm
        where hm.household_id = h.id
        order by hm.joined_at
        limit 1) actor_id
      from public.households h
  loop
    v_household_id := v_household.id;
    v_actor_id := v_household.actor_id;
    if v_actor_id is null then continue; end if;

    -- Retire the temporary cold-medicine definitions/rules. History stays.
    update public.recurrence_rules rr
       set active = false, updated_at = now()
      from public.task_definitions td
     where td.household_id = v_household_id
       and td.id = rr.task_definition_id
       and rr.household_id = v_household_id
       and rr.active
       and td.code in (
         'med_masaki_cold_am','med_shino_cold_am',
         'med_masaki_cold_pm','med_shino_cold_pm'
       );

    update public.task_definitions
       set is_active = false, updated_at = now()
     where household_id = v_household_id
       and code in (
         'med_masaki_cold_am','med_shino_cold_am',
         'med_masaki_cold_pm','med_shino_cold_pm'
       );

    update public.evening_routine_preferences erp
       set enabled = false, updated_at = now()
      from public.task_definitions td
     where td.household_id = v_household_id
       and td.id = erp.task_definition_id
       and erp.household_id = v_household_id
       and td.code in ('med_masaki_cold_pm','med_shino_cold_pm');

    -- Open routine sessions hold a FK to task_instances. Remove only the
    -- session rows attached to the cold-medicine todo instances that are about
    -- to be retired; completed/historical sessions and tasks are untouched.
    delete from public.routine_checkin_session_items si
    using public.task_instances ti, public.task_definitions td
     where si.household_id = v_household_id
       and ti.household_id = v_household_id
       and td.household_id = v_household_id
       and si.task_instance_id = ti.id
       and td.id = ti.task_definition_id
       and ti.origin = 'recurring'
       and ti.status = 'todo'
       and ti.scheduled_date >= v_today
       and td.code in (
         'med_masaki_cold_am','med_shino_cold_am',
         'med_masaki_cold_pm','med_shino_cold_pm'
       );

    delete from public.task_instances ti
    using public.task_definitions td
     where td.household_id = v_household_id
       and td.id = ti.task_definition_id
       and ti.household_id = v_household_id
       and ti.origin = 'recurring'
       and ti.status = 'todo'
       and ti.scheduled_date >= v_today
       and td.code in (
         'med_masaki_cold_am','med_shino_cold_am',
         'med_masaki_cold_pm','med_shino_cold_pm'
       );

    -- Monday: cans / PET bottles / cardboard.
    insert into public.task_definitions(
      household_id,code,title,category,routine_phase,completion_mode,is_active,
      sort_order,created_by,calendar_visibility,task_kind,include_in_routine_line
    ) values (
      v_household_id,'garbage_recyclables_mon','缶・ペットボトル・段ボールのゴミ出し',
      'garbage','morning','whole',true,60,v_actor_id,'hidden','morning_chore',true
    ) on conflict(household_id,code) do update set
      title=excluded.title,category='garbage',routine_phase='morning',completion_mode='whole',
      is_active=true,sort_order=60,calendar_visibility='hidden',task_kind='morning_chore',
      include_in_routine_line=true,updated_at=now()
    returning id into v_def_id;

    if not exists (
      select 1 from public.recurrence_rules
       where household_id=v_household_id and task_definition_id=v_def_id
         and weekday=1 and slot_key='default' and active
    ) then
      insert into public.recurrence_rules(
        household_id,task_definition_id,weekday,slot_key,assignee_strategy,
        planned_assignee_id,scheduled_local_time,effective_from,active,version,created_by
      ) values (
        v_household_id,v_def_id,1,'default','dropoff_assignee',null,
        time '07:30',v_today,true,1,v_actor_id
      );
    end if;
    select id into v_rule_id from public.recurrence_rules
     where household_id=v_household_id and task_definition_id=v_def_id
       and weekday=1 and slot_key='default' and active
     order by version desc,created_at desc limit 1;
    if v_rule_id is not null then
      perform private.materialize_recurrence_rule(v_household_id,v_rule_id,v_today,v_today+14);
    end if;

    -- Tuesday and Saturday: burnable garbage.
    insert into public.task_definitions(
      household_id,code,title,category,routine_phase,completion_mode,is_active,
      sort_order,created_by,calendar_visibility,task_kind,include_in_routine_line
    ) values (
      v_household_id,'garbage_burnable','燃えるゴミのゴミ出し','garbage','morning',
      'whole',true,61,v_actor_id,'hidden','morning_chore',true
    ) on conflict(household_id,code) do update set
      title=excluded.title,category='garbage',routine_phase='morning',completion_mode='whole',
      is_active=true,sort_order=61,calendar_visibility='hidden',task_kind='morning_chore',
      include_in_routine_line=true,updated_at=now()
    returning id into v_def_id;

    for v_weekday in select unnest(array[2,6]) loop
      if not exists (
        select 1 from public.recurrence_rules
         where household_id=v_household_id and task_definition_id=v_def_id
           and weekday=v_weekday and slot_key='default' and active
      ) then
        insert into public.recurrence_rules(
          household_id,task_definition_id,weekday,slot_key,assignee_strategy,
          planned_assignee_id,scheduled_local_time,effective_from,active,version,created_by
        ) values (
          v_household_id,v_def_id,v_weekday,'default','dropoff_assignee',null,
          time '07:30',v_today,true,1,v_actor_id
        );
      end if;
      select id into v_rule_id from public.recurrence_rules
       where household_id=v_household_id and task_definition_id=v_def_id
         and weekday=v_weekday and slot_key='default' and active
       order by version desc,created_at desc limit 1;
      if v_rule_id is not null then
        perform private.materialize_recurrence_rule(v_household_id,v_rule_id,v_today,v_today+14);
      end if;
    end loop;

    -- Wednesday: plastic garbage.
    insert into public.task_definitions(
      household_id,code,title,category,routine_phase,completion_mode,is_active,
      sort_order,created_by,calendar_visibility,task_kind,include_in_routine_line
    ) values (
      v_household_id,'garbage_plastic_wed','プラゴミのゴミ出し','garbage','morning',
      'whole',true,62,v_actor_id,'hidden','morning_chore',true
    ) on conflict(household_id,code) do update set
      title=excluded.title,category='garbage',routine_phase='morning',completion_mode='whole',
      is_active=true,sort_order=62,calendar_visibility='hidden',task_kind='morning_chore',
      include_in_routine_line=true,updated_at=now()
    returning id into v_def_id;

    if not exists (
      select 1 from public.recurrence_rules
       where household_id=v_household_id and task_definition_id=v_def_id
         and weekday=3 and slot_key='default' and active
    ) then
      insert into public.recurrence_rules(
        household_id,task_definition_id,weekday,slot_key,assignee_strategy,
        planned_assignee_id,scheduled_local_time,effective_from,active,version,created_by
      ) values (
        v_household_id,v_def_id,3,'default','dropoff_assignee',null,
        time '07:30',v_today,true,1,v_actor_id
      );
    end if;
    select id into v_rule_id from public.recurrence_rules
     where household_id=v_household_id and task_definition_id=v_def_id
       and weekday=3 and slot_key='default' and active
     order by version desc,created_at desc limit 1;
    if v_rule_id is not null then
      perform private.materialize_recurrence_rule(v_household_id,v_rule_id,v_today,v_today+14);
    end if;
  end loop;
end
$$;

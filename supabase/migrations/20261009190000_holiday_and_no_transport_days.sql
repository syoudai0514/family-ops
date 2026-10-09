-- Holidays and "no transport" days (owner 2026-10-09: 10/12 is スポーツの日; "平日のタスクはいらない。
-- 自動で無くせない？無理でも送り迎えの担当ごと削除できるように").
--
-- 1. A Japanese public holiday is not a nursery day. Nothing is made for it that belongs to a nursery
--    weekday: the dropoff / pickup legs, Codmon, and a morning routine that exists only on weekdays.
--    Daily tasks (medicine, dinner, bath...) are kept, and what followed the dropoff / pickup person
--    (the morning routine, dinner...) becomes 誰でもOK, as on a weekend.
-- 2. The same day can be cleared by hand ("この日は送迎なし"): the tasks above are cancelled (history
--    kept, never made again) and the people-dependent ones become 誰でもOK.
-- 3. The daily batch also clears a holiday that became known after its tasks were made.

create or replace function private.fn_is_jp_holiday_v1(p_date date)
returns boolean
language sql
stable
set search_path=''
as $$ select exists(select 1 from private.jp_holidays h where h.local_date=p_date); $$;

revoke all on function private.fn_is_jp_holiday_v1(date) from public,anon,authenticated;
grant execute on function private.fn_is_jp_holiday_v1(date) to service_role;

-- Does this rule's task belong to a nursery weekday (so a holiday / no-transport day drops it)?
-- Garbage collection and anything made by hand are never dropped.
create or replace function private.fn_skip_on_holiday_rule_v1(p_rule_id uuid, p_date date)
returns boolean
language sql
stable
set search_path=''
as $$
  select exists(
    select 1
    from public.recurrence_rules rr
    join public.task_definitions td on td.household_id=rr.household_id and td.id=rr.task_definition_id
    where rr.id=p_rule_id
      and td.code not like 'garbage\_%'
      and (
        rr.transport_leg is not null
        or td.code in ('dropoff','pickup')
        or td.code like 'codmon\_%'
        or (
          td.routine_phase='morning'
          and not exists(
            select 1 from public.recurrence_rules r2
            where r2.household_id=rr.household_id and r2.task_definition_id=rr.task_definition_id
              and r2.active and r2.weekday in (6,7)
              and (r2.effective_to is null or r2.effective_to>=p_date)
          )
        )
      )
  );
$$;

revoke all on function private.fn_skip_on_holiday_rule_v1(uuid,date) from public,anon,authenticated;
grant execute on function private.fn_skip_on_holiday_rule_v1(uuid,date) to service_role;

-- A holiday counts as a weekend for "whoever takes the children": 誰でもOK.
create or replace function private.fn_resolve_transport_role_assignment_v2(
  p_household_id uuid, p_date date, p_strategy text, p_fallback_assignee_id uuid
)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  v_transport_user uuid;
  v_other_user uuid;
  v_other_count int;
  v_code text;
  v_weekend boolean:=extract(isodow from p_date)::int in (6,7) or private.fn_is_jp_holiday_v1(p_date);
begin
  if p_strategy not in ('pickup_assignee','dropoff_assignee','nonpickup_adult') then
    return jsonb_build_object('mode','unassigned','user_id',null);
  end if;

  v_code:=case when p_strategy='dropoff_assignee' then 'dropoff' else 'pickup' end;

  select ti.planned_assignee_id
    into v_transport_user
  from public.task_instances ti
  join public.task_definitions td
    on td.household_id=ti.household_id and td.id=ti.task_definition_id
  where ti.household_id=p_household_id
    and ti.scheduled_date=p_date
    and td.code=v_code
    and ti.test_context_id is null
    and ti.status in ('todo','in_progress','completed')
    and coalesce(ti.assignment_mode,'person')='person'
    and ti.planned_assignee_id is not null
  order by (ti.status='completed'),ti.updated_at desc,ti.id
  limit 1;

  if p_strategy in ('pickup_assignee','dropoff_assignee') then
    if v_transport_user is not null then
      return jsonb_build_object('mode','person','user_id',v_transport_user);
    end if;
    if v_weekend then
      return jsonb_build_object('mode','anyone','user_id',null);
    end if;
    if p_fallback_assignee_id is not null then
      return jsonb_build_object('mode','person','user_id',p_fallback_assignee_id);
    end if;
    return jsonb_build_object('mode','unassigned','user_id',null);
  end if;

  if v_transport_user is not null then
    select count(*),min(hm.user_id::text)::uuid
      into v_other_count,v_other_user
    from public.household_members hm
    where hm.household_id=p_household_id
      and hm.member_role='adult'
      and hm.user_id<>v_transport_user;

    if v_other_count=1 then
      return jsonb_build_object('mode','person','user_id',v_other_user);
    end if;
  end if;

  if v_weekend then
    return jsonb_build_object('mode','anyone','user_id',null);
  end if;
  if p_fallback_assignee_id is not null then
    return jsonb_build_object('mode','person','user_id',p_fallback_assignee_id);
  end if;
  return jsonb_build_object('mode','unassigned','user_id',null);
end;
$function$;

-- Clears one day of what belongs to a nursery weekday. Open recurring tasks only; done ones and
-- ones made by hand stay.
create or replace function private.fn_clear_day_transport_v1(
  p_household_id uuid,
  p_date date,
  p_actor_user uuid,
  p_actor_ref uuid,
  p_source text,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_ref uuid:=coalesce(p_actor_ref,private.fn_household_system_actor_ref_v1(p_household_id));
  v_cancelled int:=0;
  v_loosened int:=0;
  r record;
begin
  for r in
    select ti.id
    from public.task_instances ti
    where ti.household_id=p_household_id
      and ti.scheduled_date=p_date
      and ti.test_context_id is null
      and ti.status in ('todo','in_progress')
      and ti.recurrence_rule_id is not null
      and private.fn_skip_on_holiday_rule_v1(ti.recurrence_rule_id,p_date)
    order by ti.id
    for update of ti
  loop
    update public.task_instances set status='cancelled',revision=revision+1
    where household_id=p_household_id and id=r.id;
    insert into public.task_events(
      household_id,task_instance_id,actor_id,actor_ref_id,event_type,payload,source,idempotency_key
    ) values(
      p_household_id,r.id,p_actor_user,v_ref,'cancelled',
      jsonb_build_object('reason',p_reason,'date',p_date),
      p_source,'day-without-transport:'||r.id::text
    ) on conflict do nothing;
    v_cancelled:=v_cancelled+1;
  end loop;

  -- What followed the dropoff / pickup person has no one to follow: 誰でもOK, as on a weekend.
  for r in
    select ti.id,ti.revision
    from public.task_instances ti
    join public.recurrence_rules rr on rr.household_id=ti.household_id and rr.id=ti.recurrence_rule_id
    where ti.household_id=p_household_id
      and ti.scheduled_date=p_date
      and ti.test_context_id is null
      and ti.status in ('todo','in_progress')
      and rr.assignee_strategy in ('dropoff_assignee','pickup_assignee','nonpickup_adult')
      and coalesce(ti.assignment_mode,'person')<>'anyone'
      and ti.active_claimant_actor_ref_id is null
      and coalesce(ti.assignment_source,'legacy_snapshot')='legacy_snapshot'
    order by ti.id
    for update of ti
  loop
    update public.task_instances
    set assignment_mode='anyone',planned_assignee_id=null,planned_assignee_actor_ref_id=null,revision=revision+1
    where household_id=p_household_id and id=r.id;
    insert into public.task_events(
      household_id,task_instance_id,actor_id,actor_ref_id,event_type,payload,source,idempotency_key
    ) values(
      p_household_id,r.id,p_actor_user,v_ref,'edited',
      jsonb_build_object('reason','day_without_transport','date',p_date,'assignment_mode','anyone'),
      p_source,'day-without-transport-anyone:'||r.id::text||':'||(r.revision+1)::text
    ) on conflict do nothing;
    v_loosened:=v_loosened+1;
  end loop;

  return jsonb_build_object('cancelled',v_cancelled,'made_anyone',v_loosened);
end;
$$;
revoke all on function private.fn_clear_day_transport_v1(uuid,date,uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function private.fn_clear_day_transport_v1(uuid,date,uuid,uuid,text,text) to service_role;

create or replace function public.server_tx_clear_day_transport_v1(
  p_actor_id uuid,
  p_operation_id uuid,
  p_date date
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref uuid;
  v_hash text;
  v_receipt private.mutation_receipts%rowtype;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_date is null then
    raise exception 'INVALID_INPUT';
  end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  v_actor_ref:=(v_context->>'actor_ref_id')::uuid;

  v_hash:=encode(sha256(convert_to('clear-day-transport|'||p_date::text,'UTF8')),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash,actor_ref_id)
      values(p_actor_id,p_operation_id,'clear-day-transport',v_hash,v_actor_ref)
      on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
      where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if found then
      if v_receipt.action_type<>'clear-day-transport' or v_receipt.request_hash<>v_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  v_result:=private.fn_clear_day_transport_v1(v_household_id,p_date,p_actor_id,v_actor_ref,'pwa','manual_no_transport')
    ||jsonb_build_object('ok',true,'date',p_date);
  update private.mutation_receipts set result_type='day',result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;
revoke all on function public.server_tx_clear_day_transport_v1(uuid,uuid,date) from public,anon,authenticated;
grant execute on function public.server_tx_clear_day_transport_v1(uuid,uuid,date) to service_role;

-- The daily batch: a holiday learned after its tasks were made (the table is refreshed weekly).
create or replace function public.server_tx_materialize_recurring_batch(p_today date)
 returns jsonb
 language plpgsql
 set search_path to ''
as $function$
declare
  v_rule record;
  v_household record;
  v_holiday date;
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
    return jsonb_build_object('already_ran', true, 'materialized', 0, 'failed', 0);
  end if;

  for v_rule in
    select rr.id, rr.household_id
    from public.recurrence_rules rr
    where rr.active = true
      and rr.effective_from <= p_today
      and (rr.effective_to is null or rr.effective_to >= p_today)
    order by (rr.transport_leg is null), rr.id
  loop
    begin
      perform private.materialize_recurrence_rule(
        v_rule.household_id, v_rule.id, p_today, p_today + 14
      );
      v_materialized := v_materialized + 1;
    exception when others then
      v_failed := v_failed + 1;
    end;
  end loop;

  for v_household in select h.id from public.households h loop
    for v_holiday in
      select hd.local_date from private.jp_holidays hd
      where hd.local_date between p_today and p_today + 14
        and extract(isodow from hd.local_date)::int <= 5
    loop
      begin
        perform private.fn_clear_day_transport_v1(v_household.id, v_holiday, null, null, 'holiday', 'jp_holiday');
      exception when others then
        v_failed := v_failed + 1;
      end;
    end loop;
  end loop;

  update private.worker_run_receipts
  set completed_at = now(),
      result = jsonb_build_object('materialized', v_materialized, 'failed', v_failed)
  where worker_kind = 'materialize-recurring' and logical_slot_key = p_today::text;

  return jsonb_build_object('already_ran', false, 'materialized', v_materialized, 'failed', v_failed);
end;
$function$;

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

      -- A Japanese public holiday is not a nursery day: no transport, no Codmon, no weekday-only
      -- morning routine (owner 2026-10-09). Daily tasks (medicine, dinner...) are kept.
      if extract(isodow from v_date)::int<=5
         and private.fn_is_jp_holiday_v1(v_date)
         and private.fn_skip_on_holiday_rule_v1(v_rule.id,v_date) then
        v_date:=v_date+1;
        continue;
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
          completion_mode,status,source,created_by,expectation
        ) values(
          p_household_id,v_rule.task_definition_id,v_rule.id,v_logical_key,
          'recurring',v_task.title,v_task.category,v_task.routine_phase,v_date,v_due_at,v_ends_at,
          v_planned_assignee,v_planned_actor_ref,v_assignment_mode,
          v_task.completion_mode,'todo','recurring',v_rule.created_by,
          case when v_task.default_expectation='optional' then 'optional' end
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

-- Clear the holidays already in the next two months (their tasks were made before they were known).
do $$
declare v_household record; v_holiday date;
begin
  for v_household in select h.id from public.households h loop
    for v_holiday in
      select hd.local_date from private.jp_holidays hd
      where hd.local_date between current_date and current_date + 60
        and extract(isodow from hd.local_date)::int <= 5
    loop
      perform private.fn_clear_day_transport_v1(v_household.id, v_holiday, null, null, 'holiday', 'jp_holiday');
    end loop;
  end loop;
end $$;

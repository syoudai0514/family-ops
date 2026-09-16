-- Daily Codmon contact-book coordination.
--
-- Product intent:
-- * Family Ops does NOT duplicate/store the nursery's health/meal form values.
-- * It coordinates which adult has entered each Codmon section, a hard 09:15 JST
--   send deadline, and the final human "sent" acknowledgement.
-- * Masaki pickup(+pool when the Codmon form asks for it) follows today's pickup.
-- * Shino previous-dinner/condition follows yesterday's responsible evening adult.
-- * Shino breakfast and final submit follow today's morning/dropoff adult.
-- * Shino pickup follows today's pickup adult.
-- * Final submit cannot complete before all four input acknowledgements complete.
-- * 09:00 JST emits at most one targeted reminder per adult/date.
-- * Saturdays, Sundays and Japanese holidays do not create Codmon work.
--
-- No Codmon/provider API write is performed here. Actual provider submission
-- remains an explicit human action until a separately approved integration exists.

-- ---------------------------------------------------------------------------
-- 1. First-class "yesterday evening responsible adult" recurrence strategy.
-- ---------------------------------------------------------------------------

alter table public.recurrence_rules
  drop constraint if exists recurrence_rules_assignee_strategy_check;

alter table public.recurrence_rules
  add constraint recurrence_rules_assignee_strategy_check
  check (
    assignee_strategy in (
      'fixed','dropoff_assignee','pickup_assignee','nonpickup_adult',
      'previous_evening_assignee','unassigned'
    )
  );

create or replace function private.fn_resolve_previous_evening_assignee_v1(
  p_household_id uuid,
  p_date date
) returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $resolver$
declare
  v_previous_date date:=p_date-1;
  v_user uuid;
  v_count int;
begin
  if p_household_id is null or p_date is null then
    return jsonb_build_object('mode','unassigned','user_id',null);
  end if;

  -- The previous day's actual pickup is the strongest "yesterday responsible"
  -- signal in this household. Prefer the actual performer when recorded,
  -- otherwise the final planned pickup assignee.
  select coalesce(ti.actual_completed_by_id,ti.planned_assignee_id)
    into v_user
  from public.task_instances ti
  join public.task_definitions td
    on td.household_id=ti.household_id and td.id=ti.task_definition_id
  where ti.household_id=p_household_id
    and ti.scheduled_date=v_previous_date
    and td.code='pickup'
    and ti.test_context_id is null
    and ti.status not in ('cancelled','skipped')
    and coalesce(ti.assignment_mode,'person')='person'
    and coalesce(ti.actual_completed_by_id,ti.planned_assignee_id) is not null
  order by
    case when ti.status='completed' then 0 else 1 end,
    ti.updated_at desc,
    ti.id
  limit 1;

  if v_user is not null and exists(
    select 1 from public.household_members hm
    where hm.household_id=p_household_id
      and hm.user_id=v_user
      and hm.member_role='adult'
  ) then
    return jsonb_build_object('mode','person','user_id',v_user);
  end if;

  -- If there was no usable pickup occurrence (e.g. an unusual non-transport
  -- day), accept a single unambiguous evening owner. Mixed ownership is not a
  -- reason to guess: fail closed to unassigned and let Today surface it.
  with evening_people as (
    select distinct coalesce(ti.actual_completed_by_id,ti.planned_assignee_id) as user_id
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.household_id=p_household_id
      and ti.scheduled_date=v_previous_date
      and ti.routine_phase='evening'
      and ti.test_context_id is null
      and ti.status not in ('cancelled','skipped')
      and coalesce(ti.assignment_mode,'person')='person'
      and coalesce(ti.actual_completed_by_id,ti.planned_assignee_id) is not null
      and td.code not like 'codmon_%'
  )
  select count(*),min(user_id::text)::uuid
    into v_count,v_user
  from evening_people;

  if v_count=1 and exists(
    select 1 from public.household_members hm
    where hm.household_id=p_household_id
      and hm.user_id=v_user
      and hm.member_role='adult'
  ) then
    return jsonb_build_object('mode','person','user_id',v_user);
  end if;

  return jsonb_build_object('mode','unassigned','user_id',null);
end;
$resolver$;

revoke all on function private.fn_resolve_previous_evening_assignee_v1(uuid,date)
  from public,anon,authenticated;
grant execute on function private.fn_resolve_previous_evening_assignee_v1(uuid,date)
  to service_role;

-- ---------------------------------------------------------------------------
-- 2. Preserve CURRENT materialization and add Codmon-only rules.
--
-- previous_evening_assignee is materialized only for the first date in the
-- requested range. The daily worker calls [today, today+14], so this prevents
-- tomorrow's "yesterday" owner from being guessed before tomorrow arrives.
-- ---------------------------------------------------------------------------

create or replace function private.materialize_recurrence_rule(
  p_household_id uuid,
  p_rule_id uuid,
  p_from_date date,
  p_to_date date
)
returns void
language plpgsql
set search_path=''
as $codmon_materialize$
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
$codmon_materialize$;

-- ---------------------------------------------------------------------------
-- 3. Household seed helper. This is deliberately service-only: these five
-- definitions describe this family's actual nursery workflow, not a generic
-- onboarding default for every future household.
-- ---------------------------------------------------------------------------

create or replace function private.fn_seed_codmon_daily_for_household_v1(
  p_household_id uuid,
  p_effective_from date
) returns jsonb
language plpgsql
security definer
set search_path=''
as $seed$
declare
  v_creator uuid;
  v_weekday int;
  v_row record;
  v_def_id uuid;
  v_rule_id uuid;
  v_seeded_rules int:=0;
begin
  if p_household_id is null or p_effective_from is null then
    raise exception 'INVALID_INPUT';
  end if;

  if not exists(
    select 1 from public.task_definitions
    where household_id=p_household_id and code='dropoff'
  ) or not exists(
    select 1 from public.task_definitions
    where household_id=p_household_id and code='pickup'
  ) then
    return jsonb_build_object('seeded',false,'reason','TRANSPORT_DEFINITIONS_REQUIRED');
  end if;

  select user_id into v_creator
  from public.household_members
  where household_id=p_household_id and member_role='adult'
  order by joined_at,user_id
  limit 1;
  if v_creator is null then
    return jsonb_build_object('seeded',false,'reason','ADULT_REQUIRED');
  end if;

  for v_row in
    select *
    from (values
      ('codmon_masaki_pickup_input',
       '将生：コドモン入力（迎えの人・時間／プール欄がある日は可否）',
       'pickup_assignee',44),
      ('codmon_shino_previous_input',
       '詩乃：コドモン入力（昨日の夕飯・様子）',
       'previous_evening_assignee',45),
      ('codmon_shino_breakfast_input',
       '詩乃：コドモン入力（朝食）',
       'dropoff_assignee',46),
      ('codmon_shino_pickup_input',
       '詩乃：コドモン入力（迎え）',
       'pickup_assignee',47),
      ('codmon_submit',
       'コドモン送信（将生・詩乃がそろってから）',
       'dropoff_assignee',48)
    ) as x(code,title,strategy,sort_order)
  loop
    insert into public.task_definitions(
      household_id,code,title,category,routine_phase,completion_mode,
      is_active,sort_order,created_by,calendar_visibility,task_kind,
      include_in_routine_line,default_expectation,carryover_policy,
      duplicate_sensitivity,early_completion_policy,default_duration_minutes
    ) values(
      p_household_id,v_row.code,v_row.title,'nursery','morning','whole',
      true,v_row.sort_order,v_creator,'hidden','morning_preparation',
      true,'required','occurrence_ends','normal','none',2
    )
    on conflict(household_id,code) do update
    set title=excluded.title,
        category='nursery',
        routine_phase='morning',
        completion_mode='whole',
        is_active=true,
        sort_order=excluded.sort_order,
        calendar_visibility='hidden',
        task_kind='morning_preparation',
        include_in_routine_line=true,
        default_expectation='required',
        carryover_policy='occurrence_ends',
        duplicate_sensitivity='normal',
        early_completion_policy='none',
        default_duration_minutes=2,
        updated_at=now()
    returning id into v_def_id;

    for v_weekday in 1..5 loop
      select rr.id into v_rule_id
      from public.recurrence_rules rr
      where rr.household_id=p_household_id
        and rr.task_definition_id=v_def_id
        and rr.weekday=v_weekday
        and rr.slot_key='codmon'
        and rr.active
        and rr.effective_from<=p_effective_from
        and (rr.effective_to is null or rr.effective_to>=p_effective_from)
      order by rr.version desc
      limit 1;

      if v_rule_id is null then
        insert into public.recurrence_rules(
          household_id,task_definition_id,weekday,slot_key,
          assignee_strategy,planned_assignee_id,fallback_assignee_id,
          scheduled_local_time,conflict_window_minutes,
          effective_from,effective_to,active,version,created_by
        ) values(
          p_household_id,v_def_id,v_weekday,'codmon',
          v_row.strategy,null,null,
          time '09:15',15,
          p_effective_from,null,true,1,v_creator
        )
        returning id into v_rule_id;
        v_seeded_rules:=v_seeded_rules+1;
      end if;

      -- If the requested start is today (or a test-selected day), make the
      -- first occurrence immediately available. Future daily runs own +14d.
      perform private.materialize_recurrence_rule(
        p_household_id,v_rule_id,p_effective_from,p_effective_from
      );
      v_rule_id:=null;
    end loop;
  end loop;

  return jsonb_build_object(
    'seeded',true,
    'effective_from',p_effective_from,
    'rules_created',v_seeded_rules
  );
end;
$seed$;

revoke all on function private.fn_seed_codmon_daily_for_household_v1(uuid,date)
  from public,anon,authenticated;
grant execute on function private.fn_seed_codmon_daily_for_household_v1(uuid,date)
  to service_role;

-- Seed only the already-configured target family. The Shino health definition
-- is an existing household-specific marker; this avoids turning a personal
-- workflow into a default for unrelated/new households.
do $production_seed$
declare
  v_household record;
  v_today date:=(now() at time zone 'Asia/Tokyo')::date;
  v_start date;
  v_now time:=(now() at time zone 'Asia/Tokyo')::time;
begin
  v_start:=case when v_now<time '09:15' then v_today else v_today+1 end;

  for v_household in
    select distinct td.household_id
    from public.task_definitions td
    where td.code='health_shino_med_bowel_record_am'
      and exists(
        select 1 from public.task_definitions x
        where x.household_id=td.household_id and x.code='dropoff'
      )
      and exists(
        select 1 from public.task_definitions x
        where x.household_id=td.household_id and x.code='pickup'
      )
  loop
    perform private.fn_seed_codmon_daily_for_household_v1(
      v_household.household_id,v_start
    );
  end loop;
end;
$production_seed$;

-- ---------------------------------------------------------------------------
-- 4. Final-send gate. "Sent" is a human provider acknowledgement and is only
-- legal once all four Codmon input acknowledgements for the same day are done.
-- ---------------------------------------------------------------------------

create or replace function private.fn_guard_codmon_submit_completion_v1()
returns trigger
language plpgsql
security invoker
set search_path=''
as $guard$
declare
  v_code text;
  v_completed int;
begin
  if new.status is not distinct from old.status
     or new.status<>'completed' then
    return new;
  end if;

  select code into v_code
  from public.task_definitions
  where household_id=new.household_id and id=new.task_definition_id;

  if v_code<>'codmon_submit' then
    return new;
  end if;

  select count(distinct td.code) into v_completed
  from public.task_instances ti
  join public.task_definitions td
    on td.household_id=ti.household_id and td.id=ti.task_definition_id
  where ti.household_id=new.household_id
    and ti.scheduled_date=new.scheduled_date
    and ti.test_context_id is not distinct from new.test_context_id
    and td.code in (
      'codmon_masaki_pickup_input',
      'codmon_shino_previous_input',
      'codmon_shino_breakfast_input',
      'codmon_shino_pickup_input'
    )
    and ti.status='completed';

  if v_completed<>4 then
    raise exception 'CODMON_INPUTS_INCOMPLETE';
  end if;

  return new;
end;
$guard$;

revoke all on function private.fn_guard_codmon_submit_completion_v1()
  from public,anon,authenticated;
grant execute on function private.fn_guard_codmon_submit_completion_v1()
  to service_role;

drop trigger if exists task_codmon_submit_completion_guard on public.task_instances;
create trigger task_codmon_submit_completion_guard
before update of status on public.task_instances
for each row execute function private.fn_guard_codmon_submit_completion_v1();

-- ---------------------------------------------------------------------------
-- 5. 09:00 targeted reminder. One user_notification per adult/date at most.
-- The normal canonical notification bridge carries this to LINE only when the
-- household's routine-check reminder preference/link/quota allows it.
-- ---------------------------------------------------------------------------

create or replace function private.fn_line_preference_column_for_type(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'request_received' then 'request_line'
    when 'request_accepted' then 'request_line'
    when 'request_declined' then 'request_line'
    when 'handover_created' then 'handover_line'
    when 'request.received' then 'request_line'
    when 'request.checking' then 'request_line'
    when 'request.accepted' then 'request_line'
    when 'request.declined' then 'request_line'
    when 'request.cancelled' then 'request_line'
    when 'task.completed_neutral' then 'routine_completion_line'
    when 'codmon.deadline' then 'routine_checkin_prompt_line'
    else null
  end;
$$;

revoke all on function private.fn_line_preference_column_for_type(text)
  from public,anon,authenticated;
grant execute on function private.fn_line_preference_column_for_type(text)
  to service_role;

create or replace function public.server_tx_dispatch_codmon_reminders_v1(
  p_now timestamptz default now()
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $reminder$
declare
  v_local_now timestamp;
  v_local_date date;
  v_household record;
  v_adult record;
  v_owned_titles text;
  v_unassigned_titles text;
  v_body text;
  v_incomplete_count int;
  v_submit record;
  v_actor_ref uuid;
  v_inserted int:=0;
  v_dedup text;
begin
  if p_now is null then raise exception 'INVALID_INPUT'; end if;

  v_local_now:=p_now at time zone 'Asia/Tokyo';
  v_local_date:=v_local_now::date;

  if to_char(v_local_now,'HH24:MI')<>'09:00' then
    return jsonb_build_object('due',false,'local_date',v_local_date,'notifications',0);
  end if;
  if private.fn_is_nonworkday(v_local_date) then
    return jsonb_build_object('due',false,'nonworkday',true,'local_date',v_local_date,'notifications',0);
  end if;

  for v_household in
    select distinct ti.household_id
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.scheduled_date=v_local_date
      and ti.test_context_id is null
      and td.code='codmon_submit'
      and ti.status in ('todo','in_progress')
  loop
    select ti.id,ti.planned_assignee_id,ti.assignment_mode
      into v_submit
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.household_id=v_household.household_id
      and ti.scheduled_date=v_local_date
      and ti.test_context_id is null
      and td.code='codmon_submit'
      and ti.status in ('todo','in_progress')
    order by ti.updated_at desc,ti.id
    limit 1;

    select count(*) into v_incomplete_count
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.household_id=v_household.household_id
      and ti.scheduled_date=v_local_date
      and ti.test_context_id is null
      and td.code in (
        'codmon_masaki_pickup_input',
        'codmon_shino_previous_input',
        'codmon_shino_breakfast_input',
        'codmon_shino_pickup_input'
      )
      and ti.status<>'completed';

    select string_agg('・'||ti.title,E'\n' order by td.sort_order)
      into v_unassigned_titles
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.household_id=v_household.household_id
      and ti.scheduled_date=v_local_date
      and ti.test_context_id is null
      and td.code in (
        'codmon_masaki_pickup_input',
        'codmon_shino_previous_input',
        'codmon_shino_breakfast_input',
        'codmon_shino_pickup_input'
      )
      and ti.status<>'completed'
      and (ti.planned_assignee_id is null or coalesce(ti.assignment_mode,'unassigned')<>'person');

    for v_adult in
      select hm.user_id
      from public.household_members hm
      where hm.household_id=v_household.household_id
        and hm.member_role='adult'
      order by hm.joined_at,hm.user_id
    loop
      select string_agg('・'||ti.title,E'\n' order by td.sort_order)
        into v_owned_titles
      from public.task_instances ti
      join public.task_definitions td
        on td.household_id=ti.household_id and td.id=ti.task_definition_id
      where ti.household_id=v_household.household_id
        and ti.scheduled_date=v_local_date
        and ti.test_context_id is null
        and td.code in (
          'codmon_masaki_pickup_input',
          'codmon_shino_previous_input',
          'codmon_shino_breakfast_input',
          'codmon_shino_pickup_input'
        )
        and ti.status<>'completed'
        and ti.planned_assignee_id=v_adult.user_id;

      v_body:=null;
      if v_owned_titles is not null or v_unassigned_titles is not null then
        v_body:='9:15までにコドモンを送信します。'
          ||case when v_owned_titles is not null
                 then E'\n\nあなたの入力:\n'||v_owned_titles else '' end
          ||case when v_unassigned_titles is not null
                 then E'\n\n担当未定:\n'||v_unassigned_titles else '' end
          ||E'\n\n入力がそろったら送信します。';
      elsif v_incomplete_count=0
        and (
          v_submit.planned_assignee_id=v_adult.user_id
          or v_submit.planned_assignee_id is null
          or coalesce(v_submit.assignment_mode,'unassigned')<>'person'
        ) then
        v_body:='将生・詩乃の入力がそろいました。9:15までにコドモンを送信してください。';
      end if;

      if v_body is null then continue; end if;

      select id into v_actor_ref
      from public.domain_actor_refs
      where household_id=v_household.household_id
        and actor_kind='real_user'
        and real_user_id=v_adult.user_id
        and test_context_id is null
      order by id limit 1;
      if v_actor_ref is null then continue; end if;

      v_dedup:='codmon-deadline:'||v_household.household_id::text||':'||v_adult.user_id::text||':'||v_local_date::text;
      insert into public.user_notifications(
        household_id,recipient_user_id,type,title,body,payload,dedup_key,
        recipient_actor_ref_id,notification_kind,urgency,safety_class,bundle_key,
        business_expires_at,aggregate_type,aggregate_revision,test_context_id
      ) values(
        v_household.household_id,v_adult.user_id,'codmon.deadline',
        '⏰ コドモン 9:15まで',v_body,
        jsonb_build_object('local_date',v_local_date,'deadline','09:15'),
        v_dedup,v_actor_ref,'codmon.deadline','immediate','normal',
        'codmon:'||v_household.household_id::text||':'||v_local_date::text,
        ((v_local_date::text||' 09:15')::timestamp at time zone 'Asia/Tokyo'),
        'codmon_daily',1,null
      )
      on conflict(recipient_user_id,dedup_key) do nothing;

      if found then v_inserted:=v_inserted+1; end if;
    end loop;
  end loop;

  return jsonb_build_object(
    'due',true,'local_date',v_local_date,'notifications',v_inserted
  );
end;
$reminder$;

revoke all on function public.server_tx_dispatch_codmon_reminders_v1(timestamptz)
  from public,anon,authenticated;
grant execute on function public.server_tx_dispatch_codmon_reminders_v1(timestamptz)
  to service_role;

-- Preserve DailyBrief P1 suppression exactly; Codmon is an independent
-- deadline-specific coordination lane.
create or replace function public.server_tx_dispatch_family_ops_automation_v2(
  p_now_utc timestamptz default now(),
  p_row_limit int default 2000
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_daily jsonb;
  v_codmon jsonb;
  v_legacy jsonb;
  v_p1 boolean;
begin
  v_daily:=public.server_tx_dispatch_daily_briefs(p_now_utc);
  v_codmon:=public.server_tx_dispatch_codmon_reminders_v1(p_now_utc);

  select release_stage='P1' into v_p1
  from private.canonical_capability_gates
  where capability='daily_brief_v2';

  if coalesce(v_p1,false) then
    v_legacy:=jsonb_build_object('suppressed',true,'reason','DAILY_BRIEF_P1');
  else
    v_legacy:=public.server_tx_dispatch_routine_automation(p_now_utc,p_row_limit);
  end if;

  return jsonb_build_object(
    'daily_brief',v_daily,
    'codmon',v_codmon,
    'legacy',v_legacy
  );
end;
$$;

revoke all on function public.server_tx_dispatch_family_ops_automation_v2(timestamptz,int)
  from public,anon,authenticated;
grant execute on function public.server_tx_dispatch_family_ops_automation_v2(timestamptz,int)
  to service_role;

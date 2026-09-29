-- Purpose-first PF-03: expose one canonical Codmon readiness projection to
-- Today, LINE, the submit guard and the 09:00 reminder.
-- This does NOT change bulk completion eligibility (PF-06 remains PO-deferred).

create or replace function private.fn_codmon_readiness_v1(
  p_household_id uuid,
  p_local_date date,
  p_test_context_id uuid default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_definition_count integer;
  v_instance_count integer;
  v_inputs jsonb;
  v_valid_inputs integer;
  v_completed_inputs integer;
  v_submit_count integer;
  v_submit_task_id uuid;
  v_submit_status text;
  v_submit_due_at timestamptz;
  v_submit_assignee uuid;
  v_state text;
  v_deadline timestamptz;
begin
  if p_household_id is null or p_local_date is null then
    raise exception 'INVALID_INPUT';
  end if;

  select count(distinct td.code) into v_definition_count
  from public.task_definitions td
  where td.household_id = p_household_id
    and td.code in (
      'codmon_masaki_pickup_input',
      'codmon_shino_previous_input',
      'codmon_shino_breakfast_input',
      'codmon_shino_pickup_input',
      'codmon_submit'
    );

  select count(*) into v_instance_count
  from public.task_instances ti
  join public.task_definitions td
    on td.household_id = ti.household_id
   and td.id = ti.task_definition_id
  where ti.household_id = p_household_id
    and ti.scheduled_date = p_local_date
    and ti.test_context_id is not distinct from p_test_context_id
    and td.code in (
      'codmon_masaki_pickup_input',
      'codmon_shino_previous_input',
      'codmon_shino_breakfast_input',
      'codmon_shino_pickup_input',
      'codmon_submit'
    );

  if v_definition_count = 0
     or (private.fn_is_nonworkday(p_local_date) and v_instance_count = 0) then
    return jsonb_build_object(
      'local_date', p_local_date,
      'deadline_at', null,
      'submit_task_id', null,
      'state', 'not_applicable',
      'input_completed_count', 0,
      'required_input_count', 4,
      'inputs', '[]'::jsonb,
      'submit_assignee_user_id', null
    );
  end if;

  with expected(code, fallback_title, sort_order) as (
    values
      ('codmon_masaki_pickup_input'::text, '将生：コドモン入力（迎え）'::text, 1),
      ('codmon_shino_previous_input', '詩乃：コドモン入力（昨日）', 2),
      ('codmon_shino_breakfast_input', '詩乃：コドモン入力（朝食）', 3),
      ('codmon_shino_pickup_input', '詩乃：コドモン入力（迎え）', 4)
  ), resolved as (
    select
      e.code,
      e.fallback_title,
      e.sort_order,
      m.row_count,
      m.task_id,
      coalesce(m.title, e.fallback_title) as title,
      m.planned_assignee_id,
      m.status,
      case when m.row_count = 1 then 'present'
           when m.row_count = 0 then 'missing'
           else 'duplicate' end as resolution
    from expected e
    left join lateral (
      select
        count(*)::integer as row_count,
        (array_agg(ti.id order by ti.id))[1] as task_id,
        (array_agg(ti.title order by ti.id))[1] as title,
        (array_agg(ti.planned_assignee_id order by ti.id))[1] as planned_assignee_id,
        (array_agg(ti.status order by ti.id))[1] as status
      from public.task_instances ti
      join public.task_definitions td
        on td.household_id = ti.household_id
       and td.id = ti.task_definition_id
      where ti.household_id = p_household_id
        and ti.scheduled_date = p_local_date
        and ti.test_context_id is not distinct from p_test_context_id
        and td.code = e.code
    ) m on true
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'code', r.code,
      'task_id', r.task_id,
      'title', r.title,
      'assignee_user_id', r.planned_assignee_id,
      'assignee_label', case hm.family_role
        when 'papa' then 'パパ'
        when 'mama' then 'ママ'
        else case when r.planned_assignee_id is null then '担当未定' else coalesce(p.display_name, '担当あり') end
      end,
      'status', r.status,
      'resolution', r.resolution
    ) order by r.sort_order), '[]'::jsonb),
    count(*) filter (where r.row_count = 1),
    count(*) filter (where r.row_count = 1 and r.status = 'completed')
  into v_inputs, v_valid_inputs, v_completed_inputs
  from resolved r
  left join public.household_members hm
    on hm.household_id = p_household_id
   and hm.user_id = r.planned_assignee_id
  left join public.profiles p
    on p.user_id = r.planned_assignee_id;

  select
    count(*)::integer,
    (array_agg(ti.id order by ti.id))[1],
    (array_agg(ti.status order by ti.id))[1],
    (array_agg(ti.due_at order by ti.id))[1],
    (array_agg(ti.planned_assignee_id order by ti.id))[1]
  into v_submit_count, v_submit_task_id, v_submit_status, v_submit_due_at, v_submit_assignee
  from public.task_instances ti
  join public.task_definitions td
    on td.household_id = ti.household_id
   and td.id = ti.task_definition_id
  where ti.household_id = p_household_id
    and ti.scheduled_date = p_local_date
    and ti.test_context_id is not distinct from p_test_context_id
    and td.code = 'codmon_submit';

  v_deadline := coalesce(
    v_submit_due_at,
    ((p_local_date::text || ' 09:15')::timestamp at time zone 'Asia/Tokyo')
  );

  if v_definition_count <> 5
     or v_valid_inputs <> 4
     or v_submit_count <> 1 then
    v_state := 'data_incomplete';
  elsif v_submit_status = 'completed' then
    v_state := 'acknowledged';
  elsif v_completed_inputs = 4 and v_submit_status in ('todo', 'in_progress') then
    v_state := 'ready_to_submit';
  elsif v_submit_status in ('todo', 'in_progress') then
    v_state := 'waiting_inputs';
  else
    v_state := 'data_incomplete';
  end if;

  return jsonb_build_object(
    'local_date', p_local_date,
    'deadline_at', v_deadline,
    'submit_task_id', v_submit_task_id,
    'state', v_state,
    'input_completed_count', v_completed_inputs,
    'required_input_count', 4,
    'inputs', v_inputs,
    'submit_assignee_user_id', v_submit_assignee
  );
end;
$$;

revoke all on function private.fn_codmon_readiness_v1(uuid, date, uuid)
  from public, anon, authenticated;
grant execute on function private.fn_codmon_readiness_v1(uuid, date, uuid)
  to service_role;

-- Preserve the CURRENT DailyBrief chain instead of copying an older renderer.
alter function public.server_read_daily_brief(uuid, date)
  rename to server_read_daily_brief_pre_codmon_readiness_v1;
revoke all on function public.server_read_daily_brief_pre_codmon_readiness_v1(uuid, date)
  from public, anon, authenticated;
grant execute on function public.server_read_daily_brief_pre_codmon_readiness_v1(uuid, date)
  to service_role;

create or replace function public.server_read_daily_brief(
  p_actor_id uuid,
  p_local_date date default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_brief jsonb;
  v_household_id uuid;
  v_date date;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;

  select hm.household_id into v_household_id
  from public.household_members hm
  where hm.user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  v_brief := public.server_read_daily_brief_pre_codmon_readiness_v1(
    p_actor_id, p_local_date
  );
  v_date := coalesce(
    p_local_date,
    nullif(v_brief->>'local_date', '')::date,
    (now() at time zone 'Asia/Tokyo')::date
  );

  return v_brief || jsonb_build_object(
    'codmon', private.fn_codmon_readiness_v1(
      v_household_id, v_date, null
    )
  );
end;
$$;

revoke all on function public.server_read_daily_brief(uuid, date)
  from public, anon, authenticated;
grant execute on function public.server_read_daily_brief(uuid, date)
  to service_role;

create or replace function private.fn_render_codmon_readiness_text_v1(
  p_codmon jsonb
) returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_state text := coalesce(p_codmon->>'state', '');
  v_remaining text;
begin
  if v_state in ('', 'not_applicable') then return ''; end if;

  if v_state = 'waiting_inputs' then
    select string_agg(
      coalesce(i->>'title', '入力')
      || '（' || coalesce(nullif(i->>'assignee_label',''), '担当未定') || '）',
      '、' order by ord
    ) into v_remaining
    from jsonb_array_elements(coalesce(p_codmon->'inputs', '[]'::jsonb))
      with ordinality as entries(i, ord)
    where coalesce(i->>'resolution','') <> 'present'
       or coalesce(i->>'status','') <> 'completed';

    return E'\n\nコドモン 9:15まで\n・残り: '
      || coalesce(v_remaining, '入力状況を確認してください');
  end if;

  if v_state = 'ready_to_submit' then
    return E'\n\nコドモン 9:15まで\n・入力がそろっています。コドモンで送信してください';
  end if;

  if v_state = 'data_incomplete' then
    return E'\n\nコドモン 9:15まで\n・入力状況を確認できません。更新して確認してください';
  end if;

  if v_state = 'acknowledged' then
    return E'\n\nコドモン\n・送信したと記録済み';
  end if;

  return '';
end;
$$;

revoke all on function private.fn_render_codmon_readiness_text_v1(jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_render_codmon_readiness_text_v1(jsonb)
  to service_role;

alter function public.server_render_daily_brief_text(uuid, date)
  rename to server_render_daily_brief_text_pre_codmon_v1;
revoke all on function public.server_render_daily_brief_text_pre_codmon_v1(uuid, date)
  from public, anon, authenticated;
grant execute on function public.server_render_daily_brief_text_pre_codmon_v1(uuid, date)
  to service_role;

create or replace function public.server_render_daily_brief_text(
  p_actor_id uuid,
  p_local_date date default null
) returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_brief jsonb;
  v_base text;
begin
  v_brief := public.server_read_daily_brief(p_actor_id, p_local_date);
  v_base := public.server_render_daily_brief_text_pre_codmon_v1(
    p_actor_id, p_local_date
  );
  return left(
    coalesce(v_base, '')
    || private.fn_render_codmon_readiness_text_v1(v_brief->'codmon'),
    5000
  );
end;
$$;

revoke all on function public.server_render_daily_brief_text(uuid, date)
  from public, anon, authenticated;
grant execute on function public.server_render_daily_brief_text(uuid, date)
  to service_role;

-- Completion remains an ordinary task transition. The only change is that the
-- guard consumes the same four-code readiness definition as readers/reminders.
create or replace function private.fn_guard_codmon_submit_completion_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_code text;
  v_readiness jsonb;
begin
  if new.status is not distinct from old.status
     or new.status <> 'completed' then
    return new;
  end if;

  select td.code into v_code
  from public.task_definitions td
  where td.household_id = new.household_id
    and td.id = new.task_definition_id;

  if v_code is distinct from 'codmon_submit' then
    return new;
  end if;

  v_readiness := private.fn_codmon_readiness_v1(
    new.household_id, new.scheduled_date, new.test_context_id
  );

  if v_readiness->>'state' <> 'ready_to_submit' then
    raise exception 'CODMON_INPUTS_INCOMPLETE';
  end if;

  return new;
end;
$$;

revoke all on function private.fn_guard_codmon_submit_completion_v1()
  from public, anon, authenticated;
grant execute on function private.fn_guard_codmon_submit_completion_v1()
  to service_role;

-- Keep the existing 09:00 cadence/dedup/preference bridge, but derive ready vs
-- waiting vs corrupt/missing from the shared projection.
create or replace function public.server_tx_dispatch_codmon_reminders_v1(
  p_now timestamptz default now()
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_local_now timestamp;
  v_local_date date;
  v_household record;
  v_adult record;
  v_readiness jsonb;
  v_owned_titles text;
  v_unassigned_titles text;
  v_body text;
  v_actor_ref uuid;
  v_inserted int := 0;
  v_dedup text;
begin
  if p_now is null then raise exception 'INVALID_INPUT'; end if;

  v_local_now := p_now at time zone 'Asia/Tokyo';
  v_local_date := v_local_now::date;

  if to_char(v_local_now, 'HH24:MI') <> '09:00' then
    return jsonb_build_object(
      'due', false, 'local_date', v_local_date, 'notifications', 0
    );
  end if;
  if private.fn_is_nonworkday(v_local_date) then
    return jsonb_build_object(
      'due', false, 'nonworkday', true,
      'local_date', v_local_date, 'notifications', 0
    );
  end if;

  for v_household in
    select distinct ti.household_id
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id = ti.household_id
     and td.id = ti.task_definition_id
    where ti.scheduled_date = v_local_date
      and ti.test_context_id is null
      and td.code = 'codmon_submit'
      and ti.status in ('todo', 'in_progress')
  loop
    v_readiness := private.fn_codmon_readiness_v1(
      v_household.household_id, v_local_date, null
    );

    for v_adult in
      select hm.user_id
      from public.household_members hm
      where hm.household_id = v_household.household_id
        and hm.member_role = 'adult'
      order by hm.joined_at, hm.user_id
    loop
      v_body := null;

      if v_readiness->>'state' = 'waiting_inputs' then
        select string_agg('・' || coalesce(i->>'title','入力'), E'\n' order by ord)
        into v_owned_titles
        from jsonb_array_elements(coalesce(v_readiness->'inputs','[]'::jsonb))
          with ordinality as entries(i, ord)
        where i->>'resolution' = 'present'
          and coalesce(i->>'status','') <> 'completed'
          and nullif(i->>'assignee_user_id','')::uuid = v_adult.user_id;

        select string_agg('・' || coalesce(i->>'title','入力'), E'\n' order by ord)
        into v_unassigned_titles
        from jsonb_array_elements(coalesce(v_readiness->'inputs','[]'::jsonb))
          with ordinality as entries(i, ord)
        where i->>'resolution' = 'present'
          and coalesce(i->>'status','') <> 'completed'
          and nullif(i->>'assignee_user_id','') is null;

        if v_owned_titles is not null or v_unassigned_titles is not null then
          v_body := '9:15までにコドモン送信が必要です。'
            || case when v_owned_titles is not null
                    then E'\n\nあなたの入力:\n' || v_owned_titles else '' end
            || case when v_unassigned_titles is not null
                    then E'\n\n担当未定:\n' || v_unassigned_titles else '' end
            || E'\n\n入力がそろったら送信します。';
        end if;
      elsif v_readiness->>'state' = 'ready_to_submit'
        and (
          nullif(v_readiness->>'submit_assignee_user_id','') is null
          or (v_readiness->>'submit_assignee_user_id')::uuid = v_adult.user_id
        ) then
        v_body := '将生・詩乃の入力がそろいました。9:15までにコドモンを送信してください。';
      elsif v_readiness->>'state' = 'data_incomplete' then
        v_body := 'コドモンの入力状況を確認できません。9:15までの送信前に、おうちノートを更新して入力状況を確認してください。';
      end if;

      if v_body is null then continue; end if;

      select a.id into v_actor_ref
      from public.domain_actor_refs a
      where a.household_id = v_household.household_id
        and a.actor_kind = 'real_user'
        and a.real_user_id = v_adult.user_id
        and a.test_context_id is null
      order by a.id limit 1;
      if v_actor_ref is null then continue; end if;

      v_dedup := 'codmon-deadline:'
        || v_household.household_id::text || ':'
        || v_adult.user_id::text || ':'
        || v_local_date::text;

      insert into public.user_notifications(
        household_id, recipient_user_id, type, title, body, payload, dedup_key,
        recipient_actor_ref_id, notification_kind, urgency, safety_class,
        bundle_key, business_expires_at, aggregate_type, aggregate_revision,
        test_context_id
      ) values (
        v_household.household_id, v_adult.user_id, 'codmon.deadline',
        '⏰ コドモン 9:15まで', v_body,
        jsonb_build_object(
          'local_date', v_local_date,
          'deadline', '09:15',
          'readiness_state', v_readiness->>'state'
        ),
        v_dedup, v_actor_ref, 'codmon.deadline', 'immediate', 'normal',
        'codmon:' || v_household.household_id::text || ':' || v_local_date::text,
        ((v_local_date::text || ' 09:15')::timestamp at time zone 'Asia/Tokyo'),
        'codmon_daily', 1, null
      )
      on conflict(recipient_user_id, dedup_key) do nothing;

      if found then v_inserted := v_inserted + 1; end if;
    end loop;
  end loop;

  return jsonb_build_object(
    'due', true,
    'local_date', v_local_date,
    'notifications', v_inserted
  );
end;
$$;

revoke all on function public.server_tx_dispatch_codmon_reminders_v1(timestamptz)
  from public, anon, authenticated;
grant execute on function public.server_tx_dispatch_codmon_reminders_v1(timestamptz)
  to service_role;

-- Lane D CF-02 / CF-03 / CF-04 follow-up.
-- Fix the reconciliation projection introduced by 20260909120000 and make
-- morning/daytime/evening differences presentation-only over one DailyBrief.

create or replace function private.fn_enrich_daily_brief_v2(
  p_actor_id uuid,
  p_local_date date,
  p_base jsonb
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_date date := coalesce(
    p_local_date,
    nullif(p_base->>'local_date', '')::date,
    (now() at time zone 'Asia/Tokyo')::date
  );
  v_day_end timestamptz := ((v_date + 1)::timestamp at time zone 'Asia/Tokyo');
  v_groups jsonb;
  v_reconciliation_payload jsonb := '{}'::jsonb;
  v_reconciliation_sessions jsonb := '[]'::jsonb;
  v_reconciliation_remaining integer := 0;
  v_tomorrow_base jsonb;
  v_tomorrow jsonb;
  v_partner_critical jsonb := '[]'::jsonb;
  v_unassigned jsonb := '[]'::jsonb;
  v_waiting_risk jsonb := '[]'::jsonb;
  v_urgent jsonb;
  v_partner jsonb;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;

  select hm.household_id into v_household_id
  from public.household_members hm
  where hm.user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select a.id into v_actor_ref_id
  from public.domain_actor_refs a
  where a.household_id = v_household_id
    and a.actor_kind = 'real_user'
    and a.real_user_id = p_actor_id;

  select jsonb_build_object(
    'morning', coalesce(jsonb_agg(item order by item->>'due_at', item->>'title')
      filter (where coalesce(item->>'expectation', 'normal') <> 'optional'
        and item->>'routine_phase' = 'morning'), '[]'::jsonb),
    'daytime', coalesce(jsonb_agg(item order by item->>'due_at', item->>'title')
      filter (where coalesce(item->>'expectation', 'normal') <> 'optional'
        and coalesce(item->>'routine_phase', '') not in ('morning', 'evening')), '[]'::jsonb),
    'evening', coalesce(jsonb_agg(item order by item->>'due_at', item->>'title')
      filter (where coalesce(item->>'expectation', 'normal') <> 'optional'
        and item->>'routine_phase' = 'evening'), '[]'::jsonb),
    'optional', coalesce(jsonb_agg(item order by item->>'due_at', item->>'title')
      filter (where coalesce(item->>'expectation', 'normal') = 'optional'), '[]'::jsonb)
  ) into v_groups
  from jsonb_array_elements(coalesce(p_base->'tasks', '[]'::jsonb)) item;

  -- server_read_current_routine_sessions returns an object whose `sessions`
  -- member is the array.  Never reinterpret that object as an array.
  if v_date = (now() at time zone 'Asia/Tokyo')::date then
    v_reconciliation_payload := coalesce(
      public.server_read_current_routine_sessions(p_actor_id),
      '{}'::jsonb
    );
    v_reconciliation_sessions := coalesce(
      v_reconciliation_payload->'sessions',
      '[]'::jsonb
    );
    select coalesce(sum(coalesce((item->>'remaining_count')::integer, 0)), 0)
      into v_reconciliation_remaining
    from jsonb_array_elements(v_reconciliation_sessions) item;
  end if;

  v_tomorrow_base := public.server_read_daily_brief_base_v1(p_actor_id, v_date + 1);
  v_tomorrow := jsonb_build_object(
    'local_date', v_date + 1,
    'task_count', jsonb_array_length(coalesce(v_tomorrow_base->'tasks', '[]'::jsonb)),
    'schedule_count', jsonb_array_length(coalesce(v_tomorrow_base->'schedule', '[]'::jsonb)),
    'carryover_count', jsonb_array_length(coalesce(v_tomorrow_base->'carryover', '[]'::jsonb)),
    'impact_count',
      jsonb_array_length(coalesce(v_tomorrow_base->'tasks', '[]'::jsonb))
      + jsonb_array_length(coalesce(v_tomorrow_base->'schedule', '[]'::jsonb))
      + jsonb_array_length(coalesce(v_tomorrow_base->'carryover', '[]'::jsonb)),
    'tasks', coalesce(v_tomorrow_base->'tasks', '[]'::jsonb),
    'schedule', coalesce(v_tomorrow_base->'schedule', '[]'::jsonb),
    'carryovers', coalesce(v_tomorrow_base->'carryover', '[]'::jsonb)
  );

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id', t.id,
    'title', t.title,
    'task_kind', t.task_kind,
    'due_at', t.due_at,
    'planned_assignee_actor_ref_id', t.planned_assignee_actor_ref_id,
    'revision', t.revision,
    'action_target', jsonb_build_object('kind', 'task', 'task_id', t.id, 'revision', t.revision)
  ) order by t.due_at nulls last, t.title), '[]'::jsonb)
  into v_partner_critical
  from public.task_instances t
  where t.household_id = v_household_id
    and t.test_context_id is null
    and t.scheduled_date = v_date
    and t.status in ('todo', 'in_progress')
    and t.attention_state in ('active', 'waiting')
    and t.planned_assignee_actor_ref_id is not null
    and t.planned_assignee_actor_ref_id is distinct from v_actor_ref_id
    and (
      t.task_kind = 'transport'
      or (t.due_at is not null and t.due_at < v_day_end)
      or coalesce(t.duplicate_sensitivity, 'normal') = 'safety_critical'
    );

  select coalesce(jsonb_agg(jsonb_build_object(
    'kind', 'assignment_needed',
    'task_id', t.id,
    'title', t.title,
    'due_at', t.due_at,
    'revision', t.revision,
    'action_target', jsonb_build_object('kind', 'task', 'task_id', t.id, 'revision', t.revision)
  ) order by t.due_at nulls last, t.title), '[]'::jsonb)
  into v_unassigned
  from public.task_instances t
  where t.household_id = v_household_id
    and t.test_context_id is null
    and t.scheduled_date = v_date
    and t.status in ('todo', 'in_progress')
    and t.attention_state = 'active'
    and t.planned_assignee_actor_ref_id is null
    and t.planned_assignee_id is null
    and (
      t.task_kind = 'transport'
      or (t.due_at is not null and t.due_at < v_day_end)
      or coalesce(t.duplicate_sensitivity, 'normal') = 'safety_critical'
    );

  select coalesce(jsonb_agg(item || jsonb_build_object('kind', 'waiting_risk')), '[]'::jsonb)
  into v_waiting_risk
  from jsonb_array_elements(coalesce(p_base->'waiting_checks', '[]'::jsonb)) item
  where coalesce((item->>'hard_due_risk')::boolean, false);

  v_urgent := coalesce(p_base->'urgent_actions', '[]'::jsonb)
    || v_unassigned || v_waiting_risk;
  v_partner := coalesce(p_base->'partner_summary', '{}'::jsonb)
    || jsonb_build_object('critical_items', v_partner_critical);

  return p_base || jsonb_build_object(
    'urgent_actions', v_urgent,
    'active_infos', coalesce(p_base->'handovers', '[]'::jsonb),
    'carryovers', coalesce(p_base->'carryover', '[]'::jsonb),
    'own_task_groups', v_groups,
    'partner_summary', v_partner,
    'reconciliation', jsonb_build_object(
      'sessions', v_reconciliation_sessions,
      'remaining_count', v_reconciliation_remaining,
      'actionable', v_reconciliation_remaining > 0
    ),
    'tomorrow_impact', v_tomorrow,
    'sections', coalesce(p_base->'sections', '{}'::jsonb) || jsonb_build_object(
      'confirm_first', v_urgent,
      'unusual', coalesce(p_base->'exceptions', '[]'::jsonb),
      'handover', coalesce(p_base->'handovers', '[]'::jsonb),
      'already_handled', coalesce(p_base->'already_handled', '[]'::jsonb),
      'own_task_groups', v_groups,
      'partner_summary', v_partner,
      'carryovers', coalesce(p_base->'carryover', '[]'::jsonb),
      'waiting_checks', coalesce(p_base->'waiting_checks', '[]'::jsonb),
      'reconciliation', jsonb_build_object(
        'sessions', v_reconciliation_sessions,
        'remaining_count', v_reconciliation_remaining,
        'actionable', v_reconciliation_remaining > 0
      ),
      'schedule', coalesce(p_base->'schedule', '[]'::jsonb),
      'tomorrow_impact', v_tomorrow
    )
  );
end;
$$;

revoke all on function private.fn_enrich_daily_brief_v2(uuid, date, jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_enrich_daily_brief_v2(uuid, date, jsonb)
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
  v_base jsonb;
begin
  v_base := public.server_read_daily_brief_base_v1(p_actor_id, p_local_date);
  return private.fn_enrich_daily_brief_v2(p_actor_id, p_local_date, v_base);
end;
$$;

revoke all on function public.server_read_daily_brief(uuid, date)
  from public, anon, authenticated;
grant execute on function public.server_read_daily_brief(uuid, date)
  to service_role;

create or replace function private.fn_daily_brief_lines_v1(p_items jsonb)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select string_agg(
    '・' || coalesce(
      nullif(item->>'title', ''),
      nullif(item->>'shared_text', ''),
      nullif(item->>'name', ''),
      '項目'
    ),
    E'\n'
  )
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) item
$$;

revoke all on function private.fn_daily_brief_lines_v1(jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_daily_brief_lines_v1(jsonb)
  to service_role;

create or replace function private.fn_render_daily_brief_text_v2(
  p_brief jsonb,
  p_mode text
) returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_mode text := case when p_mode in ('morning', 'daytime', 'evening') then p_mode else 'daytime' end;
  v_text text := case v_mode
    when 'morning' then '朝のおうちノート'
    when 'evening' then '夜のおうちノート'
    else '今日のおうちノート'
  end;
  v_part text;
  v_count integer;
begin
  v_part := private.fn_daily_brief_lines_v1(p_brief->'urgent_actions');
  if v_part is not null then v_text := v_text || E'\n\nまず確認\n' || v_part; end if;

  if v_mode = 'morning' then
    v_part := private.fn_daily_brief_lines_v1(p_brief->'waiting_checks');
    if v_part is not null then v_text := v_text || E'\n\n待ち・確認\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'carryovers');
    if v_part is not null then v_text := v_text || E'\n\nいつもと違うこと\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'active_infos');
    if v_part is not null then v_text := v_text || E'\n\n引き継ぎ\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'already_handled');
    if v_part is not null then v_text := v_text || E'\n\n対応済み\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'morning');
    if v_part is not null then v_text := v_text || E'\n\n朝やること\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(
      coalesce(p_brief->'own_task_groups'->'daytime', '[]'::jsonb)
      || coalesce(p_brief->'own_task_groups'->'evening', '[]'::jsonb)
    );
    if v_part is not null then v_text := v_text || E'\n\nこのあと\n' || v_part; end if;
  elsif v_mode = 'evening' then
    v_part := private.fn_daily_brief_lines_v1(
      coalesce(p_brief->'own_task_groups'->'morning', '[]'::jsonb)
      || coalesce(p_brief->'own_task_groups'->'daytime', '[]'::jsonb)
      || coalesce(p_brief->'own_task_groups'->'evening', '[]'::jsonb)
    );
    if v_part is not null then v_text := v_text || E'\n\nまだ残っていること\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'active_infos');
    if v_part is not null then v_text := v_text || E'\n\n引き継ぎ\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'partner_summary'->'critical_items');
    if v_part is not null then v_text := v_text || E'\n\n家族の重要項目\n' || v_part; end if;
    v_count := coalesce((p_brief->'tomorrow_impact'->>'impact_count')::integer, 0);
    if v_count > 0 then
      v_text := v_text || E'\n\n明日に影響\n・' || v_count::text || '件あります';
    end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'shopping');
    if v_part is not null then v_text := v_text || E'\n\n買い物\n' || v_part; end if;
    v_count := coalesce((p_brief->'reconciliation'->>'remaining_count')::integer, 0);
    if v_count > 0 then
      v_text := v_text || E'\n\nまとめ入力\n・未確認 ' || v_count::text || '件';
    end if;
  else
    v_part := private.fn_daily_brief_lines_v1(p_brief->'schedule');
    if v_part is not null then v_text := v_text || E'\n\n今日の予定\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'waiting_checks');
    if v_part is not null then v_text := v_text || E'\n\n待ち・確認\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'daytime');
    if v_part is not null then v_text := v_text || E'\n\n今やること\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(
      coalesce(p_brief->'own_task_groups'->'evening', '[]'::jsonb)
      || coalesce(p_brief->'own_task_groups'->'optional', '[]'::jsonb)
    );
    if v_part is not null then v_text := v_text || E'\n\nこのあと\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'active_infos');
    if v_part is not null then v_text := v_text || E'\n\n引き継ぎ\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'partner_summary'->'critical_items');
    if v_part is not null then v_text := v_text || E'\n\n家族の重要項目\n' || v_part; end if;
  end if;

  return left(v_text, 5000);
end;
$$;

revoke all on function private.fn_render_daily_brief_text_v2(jsonb, text)
  from public, anon, authenticated;
grant execute on function private.fn_render_daily_brief_text_v2(jsonb, text)
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
  v_date date := coalesce(p_local_date, (now() at time zone 'Asia/Tokyo')::date);
  v_now_local timestamp := now() at time zone 'Asia/Tokyo';
  v_mode text := 'daytime';
begin
  if v_date = v_now_local::date then
    v_mode := case
      when v_now_local::time < time '11:00' then 'morning'
      when v_now_local::time < time '17:00' then 'daytime'
      else 'evening'
    end;
  end if;
  return private.fn_render_daily_brief_text_v2(
    public.server_read_daily_brief(p_actor_id, v_date),
    v_mode
  );
end;
$$;

revoke all on function public.server_render_daily_brief_text(uuid, date)
  from public, anon, authenticated;
grant execute on function public.server_render_daily_brief_text(uuid, date)
  to service_role;

create or replace function public.server_tx_dispatch_daily_briefs(p_now timestamptz default now())
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_enabled boolean;
  r record;
  v_brief jsonb;
  v_receipt uuid;
  v_actor_ref uuid;
  v_dispatched int := 0;
  v_dedup text;
  v_mode text;
begin
  select writer_enabled and not mutation_paused and release_stage='P1' into v_enabled
  from private.canonical_capability_gates where capability='daily_brief_v2';
  if coalesce(v_enabled,false) is not true then
    return jsonb_build_object('enabled',false,'dispatched',0,'reason','CAPABILITY_NOT_AT_P1');
  end if;

  for r in select * from jsonb_to_recordset(public.server_read_due_daily_brief_slots(p_now)) as x(
    household_id uuid,recipient_user_id uuid,schedule_kind text,local_date date,
    local_time time,scheduled_at timestamptz,schedule_source text,dispatch_slot_key text
  ) loop
    v_receipt := null;
    insert into private.scheduled_dispatch_receipts(
      household_id,schedule_kind,scheduled_local_date,recipient_user_id,dispatch_slot_key
    ) values (r.household_id,r.schedule_kind,r.local_date,r.recipient_user_id,r.dispatch_slot_key)
    on conflict do nothing returning id into v_receipt;
    if v_receipt is null then continue; end if;

    v_brief := public.server_read_daily_brief(r.recipient_user_id,r.local_date);
    v_mode := case when r.schedule_kind='evening_brief' then 'evening' else 'morning' end;
    select id into v_actor_ref from public.domain_actor_refs where household_id=r.household_id
      and actor_kind='real_user' and real_user_id=r.recipient_user_id;
    v_dedup := 'daily-brief:'||r.dispatch_slot_key;

    insert into public.user_notifications(
      household_id,recipient_user_id,type,title,body,payload,dedup_key,
      recipient_actor_ref_id,notification_kind,urgency,safety_class,bundle_key,
      business_expires_at,aggregate_type,aggregate_revision,test_context_id
    ) values (
      r.household_id,r.recipient_user_id,'daily_brief.v2',
      case when r.schedule_kind='evening_brief' then '夜のおうちノート' else '朝のおうちノート' end,
      private.fn_render_daily_brief_text_v2(v_brief, v_mode),
      jsonb_build_object('brief',v_brief,'schedule_kind',r.schedule_kind),v_dedup,
      v_actor_ref,'daily_brief.v2','immediate','normal','daily-brief:'||r.recipient_user_id::text,
      r.scheduled_at+interval '8 hours','daily_brief',1,null
    ) on conflict(recipient_user_id,dedup_key) do nothing;
    v_dispatched := v_dispatched+1;
  end loop;

  return jsonb_build_object('enabled',true,'dispatched',v_dispatched);
end;
$$;

revoke all on function public.server_tx_dispatch_daily_briefs(timestamptz)
  from public, anon, authenticated;
grant execute on function public.server_tx_dispatch_daily_briefs(timestamptz)
  to service_role;

-- Lane D CF-02 / CF-03 / CF-04 / CF-05
-- Keep one DailyBrief semantic owner for PWA Today, LINE Today, and daily digests.
-- The already-deployed reader remains the compatibility core.  This migration
-- enriches its result without changing Request business semantics.

alter function public.server_read_daily_brief(uuid, date)
  rename to server_read_daily_brief_base_v1;

revoke all on function public.server_read_daily_brief_base_v1(uuid, date)
  from public, anon, authenticated;
grant execute on function public.server_read_daily_brief_base_v1(uuid, date)
  to service_role;

create or replace function private.fn_enrich_daily_brief_v1(
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

  -- Server-owned task grouping. React may choose how to render a group, but it
  -- must not invent a second classification of the household state.
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

  -- The same-day routine/check-in session is the canonical "まとめ入力状態".
  -- For explicit historical/future reads there is intentionally no CURRENT
  -- session projection.
  if v_date = (now() at time zone 'Asia/Tokyo')::date then
    v_reconciliation_sessions := coalesce(
      public.server_read_current_routine_sessions(p_actor_id),
      '[]'::jsonb
    );
    select coalesce(sum(coalesce((item->>'remaining_count')::integer, 0)), 0)
      into v_reconciliation_remaining
    from jsonb_array_elements(v_reconciliation_sessions) item;
  end if;

  -- Tomorrow impact reuses the exact same canonical base reader for the next
  -- local day; no React-side tomorrow task/calendar truth is permitted.
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

  -- Critical partner items must not be hidden behind counts only.
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

  -- Household tasks that still need an owner are a true "まず確認" item.
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

  select coalesce(jsonb_agg(item || jsonb_build_object('kind', 'waiting_risk')),
    '[]'::jsonb)
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

revoke all on function private.fn_enrich_daily_brief_v1(uuid, date, jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_enrich_daily_brief_v1(uuid, date, jsonb)
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
  return private.fn_enrich_daily_brief_v1(p_actor_id, p_local_date, v_base);
end;
$$;

revoke all on function public.server_read_daily_brief(uuid, date)
  from public, anon, authenticated;
grant execute on function public.server_read_daily_brief(uuid, date)
  to service_role;

-- One renderer is used by scheduled morning/evening delivery and LINE Today.
create or replace function private.fn_render_daily_brief_text_v1(p_brief jsonb)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_text text := '今日のおうちノート';
  v_part text;
  v_remaining integer := coalesce((p_brief#>>'{reconciliation,remaining_count}')::integer, 0);
  v_tomorrow_count integer := coalesce((p_brief#>>'{tomorrow_impact,impact_count}')::integer, 0);
begin
  select string_agg('・' || coalesce(x->>'title', '確認が必要な項目'), E'\n') into v_part
  from jsonb_array_elements(coalesce(p_brief->'urgent_actions', '[]'::jsonb)) x;
  if v_part is not null then v_text := v_text || E'\n\nまず確認\n' || v_part; end if;

  select string_agg('・' || coalesce(x->>'title', x->>'waiting_note', '確認待ち'), E'\n') into v_part
  from jsonb_array_elements(coalesce(p_brief->'waiting_checks', '[]'::jsonb)) x
  where not coalesce((x->>'hard_due_risk')::boolean, false);
  if v_part is not null then v_text := v_text || E'\n\n待ち\n' || v_part; end if;

  select string_agg('・' || coalesce(x->>'title', '持ち越し'), E'\n') into v_part
  from jsonb_array_elements(coalesce(p_brief->'carryovers', '[]'::jsonb)) x;
  if v_part is not null then v_text := v_text || E'\n\nいつもと違う\n' || v_part; end if;

  select string_agg('・' || coalesce(x->>'shared_text', '共有あり'), E'\n') into v_part
  from jsonb_array_elements(coalesce(p_brief->'active_infos', '[]'::jsonb)) x;
  if v_part is not null then v_text := v_text || E'\n\n引き継ぎ・共有\n' || v_part; end if;

  select string_agg('・' || coalesce(x->>'title', '完了済み'), E'\n') into v_part
  from jsonb_array_elements(coalesce(p_brief->'already_handled', '[]'::jsonb)) x;
  if v_part is not null then v_text := v_text || E'\n\nもう済んでいる\n' || v_part; end if;

  select string_agg('・' || coalesce(x->>'title', 'タスク'), E'\n') into v_part
  from jsonb_array_elements(coalesce(p_brief->'tasks', '[]'::jsonb)) x;
  if v_part is not null then v_text := v_text || E'\n\n今日やること\n' || v_part; end if;

  if v_remaining > 0 then
    v_text := v_text || E'\n\nまとめ入力\n・残り' || v_remaining::text || '件';
  end if;

  if v_tomorrow_count > 0 then
    v_text := v_text || E'\n\n明日への影響\n・' || v_tomorrow_count::text || '件';
  end if;

  select string_agg('・' || coalesce(x->>'title', '予定'), E'\n') into v_part
  from jsonb_array_elements(coalesce(p_brief->'schedule', '[]'::jsonb)) x;
  if v_part is not null then v_text := v_text || E'\n\n今日の予定\n' || v_part; end if;

  select string_agg('・' || coalesce(x->>'title', '買い物'), E'\n') into v_part
  from jsonb_array_elements(coalesce(p_brief->'shopping', '[]'::jsonb)) x;
  if v_part is not null then v_text := v_text || E'\n\n買い物\n' || v_part; end if;

  return left(v_text, 5000);
end;
$$;

revoke all on function private.fn_render_daily_brief_text_v1(jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_render_daily_brief_text_v1(jsonb)
  to service_role;

create or replace function public.server_render_daily_brief_text(
  p_actor_id uuid,
  p_local_date date default null
) returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select private.fn_render_daily_brief_text_v1(
    public.server_read_daily_brief(p_actor_id, p_local_date)
  )
$$;

revoke all on function public.server_render_daily_brief_text(uuid, date)
  from public, anon, authenticated;
grant execute on function public.server_render_daily_brief_text(uuid, date)
  to service_role;

comment on function public.server_read_daily_brief(uuid, date) is
  'Canonical DailyBrief for LINE Today, morning/evening digests, and PWA Today. Lane D CF-02.';
comment on function public.server_render_daily_brief_text(uuid, date) is
  'Canonical text renderer for DailyBrief transport surfaces.';

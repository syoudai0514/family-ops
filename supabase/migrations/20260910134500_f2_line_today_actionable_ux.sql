-- F2 real LINE review remediation.
-- Purpose -> Requirements -> real-use UX:
-- * group assignment-needed chores by daypart instead of leaking per-item times;
-- * enrich handovers with actor/ack context so LINE explains who shared what and
--   whether an explicit acknowledgement is needed;
-- * make "tomorrow impact" mean actual preparation/change/risk, not every
--   ordinary task scheduled tomorrow;
-- * preserve all canonical DailyBrief data and shared command semantics.

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
      nullif(item->>'shared_title', ''),
      nullif(item->>'shared_text', ''),
      nullif(item->>'message', ''),
      nullif(item->>'detail', ''),
      nullif(item->>'waiting_note', ''),
      nullif(item->>'name', ''),
      '確認が必要な項目'
    ),
    E'\n' order by ord
  )
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
    with ordinality as entries(item, ord)
$$;

revoke all on function private.fn_daily_brief_lines_v1(jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_daily_brief_lines_v1(jsonb)
  to service_role;

create or replace function private.fn_daily_brief_urgent_lines_v2(p_items jsonb)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  with normalized as (
    select
      item,
      ord,
      item->>'kind' as kind,
      coalesce(nullif(item->>'routine_phase', ''), 'other') as phase,
      coalesce(
        nullif(item->>'title', ''),
        nullif(item->>'shared_title', ''),
        nullif(item->>'message', ''),
        '確認が必要な項目'
      ) as label,
      case item->>'state'
        when 'pending' then '返事待ち'
        when 'checking' then '確認中'
        when 'consulting' then '相談中'
        when 'awaiting_confirmation' then '確認待ち'
        else null
      end as state_label
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
      with ordinality as entries(item, ord)
  ), ordinary as (
    select string_agg(
      '・' || label || case when state_label is not null then '（' || state_label || '）' else '' end,
      E'\n' order by ord
    ) as lines
    from normalized
    where kind is distinct from 'assignment_needed'
  ), assignment_groups as (
    select
      phase,
      min(ord) as first_ord,
      string_agg('・' || label, E'\n' order by ord) as lines
    from normalized
    where kind = 'assignment_needed'
    group by phase
  ), assignments as (
    select string_agg(
      '担当未定（' || case phase
        when 'morning' then '朝'
        when 'evening' then '夜'
        else '日中'
      end || '）' || E'\n' || lines,
      E'\n' order by case phase when 'morning' then 1 when 'other' then 2 when 'evening' then 3 else 2 end, first_ord
    ) as lines
    from assignment_groups
  )
  select nullif(concat_ws(E'\n', ordinary.lines, assignments.lines), '')
  from ordinary cross join assignments
$$;

revoke all on function private.fn_daily_brief_urgent_lines_v2(jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_daily_brief_urgent_lines_v2(jsonb)
  to service_role;

create or replace function private.fn_daily_brief_handover_lines_v1(p_items jsonb)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select string_agg(
    '・'
    || case item->>'author_role'
      when 'papa' then 'パパ'
      when 'mama' then 'ママ'
      else coalesce(nullif(item->>'author_label', ''), '家族')
    end
    || ' → ' || coalesce(nullif(item->>'audience_label', ''), '家族')
    || '｜' || case item->>'info_kind' when 'share' then '共有' else '引き継ぎ' end
    || '｜' || case
      when coalesce(item->>'ack_policy', 'none') = 'required' then '確認待ち（LINEで「共有確認」）'
      else '確認不要'
    end
    || E'\n  '
    || replace(coalesce(nullif(item->>'shared_text', ''), '内容なし'), E'\n', E'\n  '),
    E'\n' order by ord
  )
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
    with ordinality as entries(item, ord)
$$;

revoke all on function private.fn_daily_brief_handover_lines_v1(jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_daily_brief_handover_lines_v1(jsonb)
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
  v_brief jsonb;
  v_household_id uuid;
  v_urgent jsonb := '[]'::jsonb;
  v_active_infos jsonb := '[]'::jsonb;
  v_tomorrow jsonb := '{}'::jsonb;
  v_impact_tasks jsonb := '[]'::jsonb;
  v_impact_count integer := 0;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;

  select hm.household_id into v_household_id
  from public.household_members hm
  where hm.user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  v_base := public.server_read_daily_brief_base_v1(p_actor_id, p_local_date);
  v_brief := private.fn_enrich_daily_brief_v2(p_actor_id, p_local_date, v_base);

  select coalesce(jsonb_agg(
    case
      when item->>'kind' = 'assignment_needed' and nullif(item->>'task_id', '') is not null then
        item || jsonb_strip_nulls(jsonb_build_object(
          'routine_phase', t.routine_phase,
          'expectation', t.expectation,
          'category', t.category
        ))
      else item
    end
    order by ord
  ), '[]'::jsonb)
  into v_urgent
  from jsonb_array_elements(coalesce(v_brief->'urgent_actions', '[]'::jsonb))
    with ordinality as entries(item, ord)
  left join public.task_instances t
    on item->>'kind' = 'assignment_needed'
   and t.household_id = v_household_id
   and t.id = (item->>'task_id')::uuid;

  select coalesce(jsonb_agg(
    item || jsonb_build_object(
      'info_kind', h.info_kind,
      'author_role', coalesce(author_member.family_role, author_ref.simulated_role, author_ref.actor_kind, 'family'),
      'audience_label', case h.visibility when 'self' then '自分' else '家族' end,
      'ack_status', case h.ack_policy when 'required' then '確認待ち' else '確認不要' end
    )
    order by ord
  ), '[]'::jsonb)
  into v_active_infos
  from jsonb_array_elements(coalesce(v_brief->'active_infos', '[]'::jsonb))
    with ordinality as entries(item, ord)
  join public.handovers h
    on h.household_id = v_household_id
   and h.id = (item->>'handover_id')::uuid
  left join public.domain_actor_refs author_ref on author_ref.id = h.author_actor_ref_id
  left join public.household_members author_member
    on author_member.household_id = h.household_id
   and author_member.user_id = author_ref.real_user_id;

  v_tomorrow := coalesce(v_brief->'tomorrow_impact', '{}'::jsonb);
  select coalesce(jsonb_agg(item order by ord), '[]'::jsonb)
    into v_impact_tasks
  from jsonb_array_elements(coalesce(v_tomorrow->'tasks', '[]'::jsonb))
    with ordinality as entries(item, ord)
  where item->>'task_kind' = 'morning_preparation'
     or item->>'category' = 'preparation'
     or item->>'duplicate_sensitivity' = 'safety_critical';

  v_impact_count := jsonb_array_length(v_impact_tasks)
    + jsonb_array_length(coalesce(v_tomorrow->'schedule', '[]'::jsonb))
    + jsonb_array_length(coalesce(v_tomorrow->'carryovers', '[]'::jsonb));

  v_tomorrow := v_tomorrow || jsonb_build_object(
    'tasks', v_impact_tasks,
    'task_count', jsonb_array_length(v_impact_tasks),
    'impact_count', v_impact_count
  );

  v_brief := v_brief || jsonb_build_object(
    'urgent_actions', v_urgent,
    'active_infos', v_active_infos,
    'tomorrow_impact', v_tomorrow,
    'sections', coalesce(v_brief->'sections', '{}'::jsonb) || jsonb_build_object(
      'confirm_first', v_urgent,
      'handover', v_active_infos,
      'tomorrow_impact', v_tomorrow
    )
  );

  return v_brief || jsonb_build_object(
    'morning_summary', private.fn_daily_brief_morning_summary_v1(v_brief)
  );
end;
$$;

create or replace function private.fn_render_daily_brief_text_v3(
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
  v_morning_completed integer := coalesce((p_brief#>>'{morning_summary,completed_count}')::integer, 0);
  v_morning_total integer := coalesce((p_brief#>>'{morning_summary,total_count}')::integer, 0);
  v_partner_open integer := coalesce((p_brief#>>'{partner_summary,open_assigned}')::integer, 0);
  v_partner_waiting integer := coalesce((p_brief#>>'{partner_summary,waiting}')::integer, 0);
  v_partner_completed integer := coalesce((p_brief#>>'{partner_summary,completed_today}')::integer, 0);
begin
  v_part := private.fn_daily_brief_urgent_lines_v2(p_brief->'urgent_actions');
  if v_part is not null then v_text := v_text || E'\n\nまず確認\n' || v_part; end if;

  v_part := private.fn_daily_brief_lines_v1(
    coalesce(p_brief->'exceptions', '[]'::jsonb)
    || coalesce(p_brief->'carryovers', '[]'::jsonb)
  );
  if v_part is not null then v_text := v_text || E'\n\nいつもと違うこと\n' || v_part; end if;

  v_part := private.fn_daily_brief_handover_lines_v1(p_brief->'active_infos');
  if v_part is not null then v_text := v_text || E'\n\n引き継ぎ・共有\n' || v_part; end if;

  if v_mode = 'morning' then
    v_part := private.fn_daily_brief_lines_v1(p_brief->'already_handled');
    if v_part is not null then v_text := v_text || E'\n\nもう済んでいる\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'waiting_checks');
    if v_part is not null then v_text := v_text || E'\n\n待ち・確認\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'schedule');
    if v_part is not null then v_text := v_text || E'\n\n今日の予定\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'morning');
    if v_part is not null then v_text := v_text || E'\n\n朝やること\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'daytime');
    if v_part is not null then v_text := v_text || E'\n\n日中にやること\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'evening');
    if v_part is not null then v_text := v_text || E'\n\n夜にやること\n' || v_part; end if;
  elsif v_mode = 'evening' then
    if v_morning_total > 0 then
      v_text := v_text || E'\n\nもう済んでいる\n・朝 ' || v_morning_completed::text || '/' || v_morning_total::text || ' 完了';
    end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'waiting_checks');
    if v_part is not null then v_text := v_text || E'\n\n待ち・確認\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'schedule');
    if v_part is not null then v_text := v_text || E'\n\n今日の予定\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(
      coalesce(p_brief->'own_task_groups'->'morning', '[]'::jsonb)
      || coalesce(p_brief->'own_task_groups'->'daytime', '[]'::jsonb)
    );
    if v_part is not null then v_text := v_text || E'\n\nまだ残っていること\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'evening');
    if v_part is not null then v_text := v_text || E'\n\n夜にやること\n' || v_part; end if;
  else
    v_part := private.fn_daily_brief_lines_v1(p_brief->'already_handled');
    if v_part is not null then v_text := v_text || E'\n\nもう済んでいる\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'waiting_checks');
    if v_part is not null then v_text := v_text || E'\n\n待ち・確認\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'schedule');
    if v_part is not null then v_text := v_text || E'\n\n今日の予定\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'morning');
    if v_part is not null then v_text := v_text || E'\n\n朝の残り\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'daytime');
    if v_part is not null then v_text := v_text || E'\n\n今やること\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'evening');
    if v_part is not null then v_text := v_text || E'\n\nこのあと（夜）\n' || v_part; end if;
  end if;

  v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'optional');
  if v_part is not null then v_text := v_text || E'\n\n余力があれば\n' || v_part; end if;

  v_part := private.fn_daily_brief_lines_v1(p_brief->'partner_summary'->'critical_items');
  if v_partner_open > 0 or v_partner_waiting > 0 or v_partner_completed > 0 or v_part is not null then
    v_text := v_text || E'\n\n相手の今日';
    if v_partner_open > 0 or v_partner_waiting > 0 or v_partner_completed > 0 then
      v_text := v_text || E'\n・残り ' || v_partner_open::text
        || '件・待ち ' || v_partner_waiting::text
        || '件・完了 ' || v_partner_completed::text || '件';
    end if;
    if v_part is not null then v_text := v_text || E'\n' || v_part; end if;
  end if;

  v_part := private.fn_daily_brief_lines_v1(
    coalesce(p_brief->'tomorrow_impact'->'tasks', '[]'::jsonb)
    || coalesce(p_brief->'tomorrow_impact'->'schedule', '[]'::jsonb)
    || coalesce(p_brief->'tomorrow_impact'->'carryovers', '[]'::jsonb)
  );
  if v_part is not null then
    v_text := v_text || E'\n\n明日の準備・変更\n' || v_part;
  end if;

  if coalesce((p_brief#>>'{reconciliation,remaining_count}')::integer, 0) > 0 then
    v_text := v_text || E'\n\nまとめ入力\n・未確認 '
      || (p_brief#>>'{reconciliation,remaining_count}') || '件';
  end if;

  if v_mode = 'evening' then
    v_part := private.fn_daily_brief_lines_v1(p_brief->'shopping');
    if v_part is not null then v_text := v_text || E'\n\n買い物\n' || v_part; end if;
  end if;

  return left(v_text, 5000);
end;
$$;

revoke all on function private.fn_render_daily_brief_text_v3(jsonb, text)
  from public, anon, authenticated;
grant execute on function private.fn_render_daily_brief_text_v3(jsonb, text)
  to service_role;

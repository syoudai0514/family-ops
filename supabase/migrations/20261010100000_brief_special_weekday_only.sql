-- Owner 2026-10-10: the brief's "今日だけ" block.
--  * It is made on weekdays only. On a weekend or a holiday the weekly rhythm is different, so
--    nothing is "unusual" for the day (the weekend chores sat under 今日だけ（いつもと違う）).
--  * Its heading says what it is compared with: 平日は毎日ないこと.

create or replace function private.fn_brief_split_special_v1(p_brief jsonb)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with groups as (
    select g.k, g.ord, coalesce(p_brief->'own_task_groups'->g.k, '[]'::jsonb) as v
    from unnest(array['morning','daytime','evening']) with ordinality as g(k, ord)
  ), items as (
    select g.k, g.ord as gord, t.item, t.iord, nullif(t.item->>'task_id','')::uuid as task_id
    from groups g
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(g.v) = 'array' then g.v else '[]'::jsonb end
    ) with ordinality as t(item, iord)
  ), special as (
    select i.k, i.gord, i.iord, i.item
    from items i
    join public.task_instances ti on ti.id = i.task_id
    -- Only on a weekday: "not every weekday" says nothing on a weekend or a holiday, when
    -- the weekly rhythm is different and nothing is "unusual" for the day (owner 2026-10-10).
    where not private.fn_is_nonworkday(ti.scheduled_date)
      and (
       ti.task_definition_id is null
       or (
         select count(distinct r.weekday)
         from public.recurrence_rules r
         where r.task_definition_id = ti.task_definition_id
           and r.active
           and r.weekday between 1 and 5
           and r.effective_from <= ti.scheduled_date
           and (r.effective_to is null or r.effective_to >= ti.scheduled_date)
       ) < 5
      )
  )
  select p_brief
    || jsonb_build_object('special_today', coalesce((
         select jsonb_agg(s.item order by s.gord, s.iord) from special s
       ), '[]'::jsonb))
    || jsonb_build_object('own_task_groups',
         coalesce(p_brief->'own_task_groups', '{}'::jsonb)
         || jsonb_build_object(
              'morning', coalesce((select jsonb_agg(i.item order by i.iord) from items i
                                   where i.k = 'morning'
                                     and not exists (select 1 from special s where s.k = i.k and s.iord = i.iord)), '[]'::jsonb),
              'daytime', coalesce((select jsonb_agg(i.item order by i.iord) from items i
                                   where i.k = 'daytime'
                                     and not exists (select 1 from special s where s.k = i.k and s.iord = i.iord)), '[]'::jsonb),
              'evening', coalesce((select jsonb_agg(i.item order by i.iord) from items i
                                   where i.k = 'evening'
                                     and not exists (select 1 from special s where s.k = i.k and s.iord = i.iord)), '[]'::jsonb)
            ))
$$;
revoke all on function private.fn_brief_split_special_v1(jsonb) from public, anon, authenticated;
grant execute on function private.fn_brief_split_special_v1(jsonb) to service_role;

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

  -- Tasks that do not happen every weekday (owner decision 2026-09-30, Requirements
  -- §29.8): the things to remember today that the daily routine will not remind you of.
  v_part := private.fn_daily_brief_lines_v1(p_brief->'special_today');
  if v_part is not null then v_text := v_text || E'\n\n⭐ 今日だけ（平日は毎日ないこと）\n' || v_part; end if;

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
    if v_morning_completed > 0 then
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

  -- Partner: what changes the reader's own plans, never a score. The
  -- "残り N件・待ち N件・完了 N件" line was removed from the PWA in aee0115; LINE
  -- kept printing it (live: "残り 9件・待ち 0件・完了 0件") plus every partner
  -- task, which is the same scorekeeping Requirements §3 forbids.
  v_part := private.fn_daily_brief_lines_v1((
    select coalesce(jsonb_agg(e order by o), '[]'::jsonb)
    from jsonb_array_elements(coalesce(p_brief->'partner_summary'->'critical_items','[]'::jsonb))
      with ordinality as x(e, o)
    where o <= 3
  ));
  if v_part is not null then
    v_text := v_text || E'\n\n相手の今日\n' || v_part;
    if jsonb_array_length(coalesce(p_brief->'partner_summary'->'critical_items','[]'::jsonb)) > 3 then
      v_text := v_text || E'\n・ほか '
        || (jsonb_array_length(p_brief->'partner_summary'->'critical_items') - 3)::text || '件';
    end if;
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

revoke all on function private.fn_render_daily_brief_text_v3(jsonb, text) from public, anon, authenticated;
grant execute on function private.fn_render_daily_brief_text_v3(jsonb, text) to service_role;

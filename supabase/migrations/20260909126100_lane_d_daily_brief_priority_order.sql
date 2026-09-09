-- Lane D CF-04 final priority-order hardening.
-- Presentation-only redefinition: preserve the same canonical DailyBrief data,
-- but keep material sections in the approved order before ordinary work.

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
  v_count integer;
  v_morning_completed integer := coalesce((p_brief#>>'{morning_summary,completed_count}')::integer, 0);
  v_morning_total integer := coalesce((p_brief#>>'{morning_summary,total_count}')::integer, 0);
begin
  v_part := private.fn_daily_brief_lines_v1(p_brief->'urgent_actions');
  if v_part is not null then v_text := v_text || E'\n\nまず確認\n' || v_part; end if;

  v_part := private.fn_daily_brief_lines_v1(
    coalesce(p_brief->'exceptions', '[]'::jsonb)
    || coalesce(p_brief->'carryovers', '[]'::jsonb)
  );
  if v_part is not null then v_text := v_text || E'\n\nいつもと違うこと\n' || v_part; end if;

  if v_mode = 'morning' then
    v_part := private.fn_daily_brief_lines_v1(p_brief->'waiting_checks');
    if v_part is not null then v_text := v_text || E'\n\n待ち・確認\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'active_infos');
    if v_part is not null then v_text := v_text || E'\n\n引き継ぎ・共有\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'already_handled');
    if v_part is not null then v_text := v_text || E'\n\nもう済んでいる\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'morning');
    if v_part is not null then v_text := v_text || E'\n\n朝やること\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(
      coalesce(p_brief->'own_task_groups'->'daytime', '[]'::jsonb)
      || coalesce(p_brief->'own_task_groups'->'evening', '[]'::jsonb)
    );
    if v_part is not null then v_text := v_text || E'\n\nこのあと\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'schedule');
    if v_part is not null then v_text := v_text || E'\n\n今日の予定\n' || v_part; end if;
  elsif v_mode = 'evening' then
    v_part := private.fn_daily_brief_lines_v1(p_brief->'active_infos');
    if v_part is not null then v_text := v_text || E'\n\n引き継ぎ・共有\n' || v_part; end if;
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
      || coalesce(p_brief->'own_task_groups'->'evening', '[]'::jsonb)
    );
    if v_part is not null then v_text := v_text || E'\n\nまだ残っていること\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'partner_summary'->'critical_items');
    if v_part is not null then v_text := v_text || E'\n\n家族の重要項目\n' || v_part; end if;
    v_count := coalesce((p_brief#>>'{tomorrow_impact,impact_count}')::integer, 0);
    if v_count > 0 then
      v_text := v_text || E'\n\n明日に影響\n・' || v_count::text || '件あります';
    end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'shopping');
    if v_part is not null then v_text := v_text || E'\n\n買い物\n' || v_part; end if;
    v_count := coalesce((p_brief#>>'{reconciliation,remaining_count}')::integer, 0);
    if v_count > 0 then
      v_text := v_text || E'\n\nまとめ入力\n・未確認 ' || v_count::text || '件';
    end if;
  else
    v_part := private.fn_daily_brief_lines_v1(p_brief->'active_infos');
    if v_part is not null then v_text := v_text || E'\n\n引き継ぎ・共有\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'already_handled');
    if v_part is not null then v_text := v_text || E'\n\nもう済んでいる\n' || v_part; end if;
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
    v_part := private.fn_daily_brief_lines_v1(p_brief->'partner_summary'->'critical_items');
    if v_part is not null then v_text := v_text || E'\n\n家族の重要項目\n' || v_part; end if;
  end if;

  return left(v_text, 5000);
end;
$$;

revoke all on function private.fn_render_daily_brief_text_v3(jsonb, text)
  from public, anon, authenticated;
grant execute on function private.fn_render_daily_brief_text_v3(jsonb, text)
  to service_role;

-- Render the already household-visible schedule at the top of the note.
-- Both Family Events and Google occurrences use the same format.
create function private.fn_line_today_schedule_lines_v1(p_schedule jsonb)
returns text language sql stable security invoker set search_path='' as $$
  with entries as (
    select item, ord, item->>'is_all_day' is not distinct from 'true' as all_day,
      case when pg_input_is_valid(item->>'starts_at','timestamp with time zone')
        then (item->>'starts_at')::timestamptz end as starts_at
    from jsonb_array_elements(case when jsonb_typeof(p_schedule)='array'
      then p_schedule else '[]'::jsonb end) with ordinality as x(item,ord)
  )
  select string_agg('・' || case when all_day then '終日 '
    when starts_at is not null then to_char(starts_at at time zone 'Asia/Tokyo','HH24:MI') || ' '
    else '' end || coalesce(nullif(item->>'display_title',''),nullif(item->>'title',''),'名称未設定'),
    E'\n' order by all_day desc,starts_at nulls last,ord)
  from entries;
$$;
revoke all on function private.fn_line_today_schedule_lines_v1(jsonb) from public,anon,authenticated;
grant execute on function private.fn_line_today_schedule_lines_v1(jsonb) to service_role;

-- Keep the evening/recipient wrapper from #243. This shared renderer controls
-- position before the message is truncated and avoids editing rendered titles.
create or replace function private.fn_render_daily_brief_before_evening_calm_v1(p_brief jsonb,p_mode text)
returns text language plpgsql stable security invoker set search_path = '' as $$
declare
  -- The scheduled morning note orders the chores by time and summarizes the evening.
  -- The interactive 今日 reply keeps the full list.
  focus boolean:=p_mode='morning_focus';
  mode text:=case when p_mode in ('morning','morning_focus') then 'morning' when p_mode in ('daytime','evening') then p_mode else 'daytime' end;
  body text:=case mode when 'morning' then '朝のおうちノート' when 'evening' then '夜のおうちノート' else '今日のおうちノート' end;
  part text; phase text; heading text; recipient text:=p_brief->>'display_recipient_user_id';
  all_tasks jsonb; partner_items jsonb; optional_items jsonb; tomorrow jsonb; tomorrow_date date; later_count integer;
begin
  part:=private.fn_daily_brief_urgent_lines_v2(p_brief->'urgent_actions');
  if part is not null then body:=body||E'\n\nまず確認\n'||part; end if;
  part:=private.fn_line_today_schedule_lines_v1(p_brief->'schedule');
  if part is not null then body:=body||E'\n\n⭐ 今日の予定\n'||part; end if;
  part:=private.fn_line_task_groups_v1(p_brief->'special_today',recipient,true);
  if part is not null then body:=body||E'\n\n⭐ 今日、忘れずに\n'||part; end if;
  if focus then
    part:=private.fn_line_task_timeline_v1(p_brief->'own_task_groups'->'morning',recipient);
    if part is not null then body:=body||E'\n\n⏰ 朝やること（時刻順）\n'||part; end if;
  end if;
  part:=private.fn_daily_brief_lines_v1(coalesce(p_brief->'exceptions','[]'::jsonb)||coalesce(p_brief->'carryovers','[]'::jsonb));
  if part is not null then body:=body||E'\n\nいつもと違うこと\n'||part; end if;
  if mode='morning' then
    part:=private.fn_daily_brief_lines_v1(p_brief->'already_handled');
    if part is not null then body:=body||E'\n\nもう済んでいる\n'||part; end if;
  end if;
  part:=private.fn_daily_brief_lines_v1(p_brief->'waiting_checks');
  if part is not null then body:=body||E'\n\n待ち・確認\n'||part; end if;
  for phase in select unnest(array['morning','daytime','evening']) loop
    continue when focus and phase in ('morning','evening');
    heading:=case phase when 'morning' then case mode when 'morning' then '朝やること' else '朝の残り' end
      when 'daytime' then case mode when 'evening' then '日中の残り' when 'daytime' then '今やること' else '日中にやること' end
      else case mode when 'daytime' then 'このあと（夜）' else '夜にやること' end end;
    part:=private.fn_line_task_groups_v1(p_brief->'own_task_groups'->phase,recipient,focus);
    if part is not null then body:=body||E'\n\n'||heading||E'\n'||part; end if;
  end loop;
  part:=private.fn_daily_brief_handover_lines_v1(p_brief->'active_infos');
  if part is not null then body:=body||E'\n\n引き継ぎ・共有\n'||part; end if;
  if focus then
    later_count:=jsonb_array_length(coalesce(p_brief->'own_task_groups'->'evening','[]'::jsonb));
    if later_count>0 then body:=body||E'\n\n夜にやること\n・'||later_count||E'件（夜のおうちノートでお知らせします）'; end if;
  end if;
  select coalesce(jsonb_agg(item order by ord),'[]'::jsonb) into optional_items
  from jsonb_array_elements(coalesce(p_brief->'own_task_groups'->'optional','[]'::jsonb)) with ordinality x(item,ord)
  where nullif(item->>'active_claimant_user_id','') is null or recipient is null or item->>'active_claimant_user_id'=recipient;
  part:=case when focus then null else private.fn_line_task_lines_v1(optional_items,false,true) end;
  if part is not null then body:=body||E'\n\n余裕があれば\n'||part; end if;

  all_tasks:=coalesce(p_brief->'special_today','[]'::jsonb)||coalesce(p_brief->'own_task_groups'->'morning','[]'::jsonb)
    ||coalesce(p_brief->'own_task_groups'->'daytime','[]'::jsonb)||coalesce(p_brief->'own_task_groups'->'evening','[]'::jsonb)
    ||coalesce(p_brief->'own_task_groups'->'optional','[]'::jsonb);
  select coalesce(jsonb_agg(item order by ord),'[]'::jsonb) into partner_items
  from (select distinct on (coalesce(item->>'task_id',item->>'title')) item,ord
    from jsonb_array_elements(coalesce(p_brief->'partner_summary'->'critical_items','[]'::jsonb)||all_tasks) with ordinality x(item,ord)
    where ord<=jsonb_array_length(coalesce(p_brief->'partner_summary'->'critical_items','[]'::jsonb))
      or (recipient is not null and nullif(item->>'active_claimant_user_id','') is not null and item->>'active_claimant_user_id'<>recipient)
    order by coalesce(item->>'task_id',item->>'title'),ord) unique_items;
  part:=private.fn_line_task_lines_v1((select coalesce(jsonb_agg(item order by ord),'[]'::jsonb)
    from jsonb_array_elements(partner_items) with ordinality x(item,ord) where ord<=3));
  if part is not null then
    body:=body||E'\n\n相手の担当で確認したいこと\n'||part;
    if jsonb_array_length(partner_items)>3 then body:=body||E'\n・ほか '||(jsonb_array_length(partner_items)-3)::text||'件'; end if;
  end if;
  tomorrow:=coalesce(p_brief->'tomorrow_impact','{}'::jsonb);
  tomorrow_date:=nullif(tomorrow->>'local_date','')::date;
  part:=case when focus then null else private.fn_line_task_lines_v1(coalesce(tomorrow->'tasks','[]'::jsonb)||coalesce(tomorrow->'schedule','[]'::jsonb)
    ||coalesce(tomorrow->'carryovers','[]'::jsonb),true) end;
  if part is not null then
    heading:=case when tomorrow_date is null then '明日の予定・作業' else '明日 '||to_char(tomorrow_date,'FMMM/FMDD')
      ||'('||(array['月','火','水','木','金','土','日'])[extract(isodow from tomorrow_date)::int]||')の予定・作業' end;
    body:=body||E'\n\n'||heading||E'\n'||part;
  end if;
  if coalesce((p_brief#>>'{reconciliation,remaining_count}')::integer,0)>0 then
    body:=body||E'\n\n朝・夜の記録\n・未確認 '||(p_brief#>>'{reconciliation,remaining_count}')||'件';
  end if;
  if mode='evening' then
    part:=private.fn_daily_brief_lines_v1(p_brief->'shopping');
    if part is not null then body:=body||E'\n\n買い物\n'||part; end if;
  end if;
  return left(body,5000);
end $$;
revoke all on function private.fn_render_daily_brief_before_evening_calm_v1(jsonb,text) from public,anon,authenticated;
grant execute on function private.fn_render_daily_brief_before_evening_calm_v1(jsonb,text) to service_role;

alter function private.fn_render_daily_brief_text_v4(jsonb,text) stable;

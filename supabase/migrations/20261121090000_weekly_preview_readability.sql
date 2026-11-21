-- Format the three weekly sources together so a family-calendar mirror does
-- not repeat a special task or its deadline. Keep separate same-source events.
create or replace function private.fn_weekly_preview_lines_v1(
  p_calendar text, p_special text, p_highlights text, p_has_transport boolean
) returns text
language sql stable security invoker set search_path = ''
as $$
  with raw as (
    select source, ordinal, line
    from (values (1, p_calendar), (2, p_special), (3, p_highlights)) s(source, lines)
    cross join lateral unnest(string_to_array(s.lines, E'\n')) with ordinality as u(line, ordinal)
    where line <> ''
  ), parsed as (
    select source, ordinal,
      regexp_replace(line, '\s*\[未\]$', '') as line,
      line ~ '^・[0-9]{1,2}:[0-9]{2}\s' as timed,
      regexp_replace(
        regexp_replace(
          regexp_replace(line, '^・([0-9]{1,2}:[0-9]{2}\s+)?', ''),
          '\s*\[未\]$', ''
        ), '\s*\(期限[0-9/ :]+\)$', ''
      ) as title
    from raw
  )
  select string_agg(p.line, E'\n' order by p.source, p.ordinal)
  from parsed p
  where not (p_has_transport and p.source = 1 and p.title ~ '^送[PM]迎[PM]$')
    and not exists (
      select 1 from parsed earlier
      where p.source = 2 and earlier.source = 1
        and earlier.title = p.title
        and (not earlier.timed or not p.timed)
    );
$$;
revoke all on function private.fn_weekly_preview_lines_v1(text, text, text, boolean) from public, anon, authenticated;
grant execute on function private.fn_weekly_preview_lines_v1(text, text, text, boolean) to service_role;

create or replace function private.fn_render_weekly_preview_v1(
  p_household_id uuid,
  p_monday date
) returns text
language plpgsql stable security invoker set search_path = ''
as $$
declare
  v_day date;
  v_dropoff text;
  v_pickup text;
  v_special text;
  v_cal text;
  v_hl text;
  v_block text;
  v_out text := '';
begin
  for v_day in select d::date from generate_series(p_monday, p_monday + 6, interval '1 day') d loop
    select regexp_replace(coalesce(p.display_name,'未定'), '（仮）$', '') into v_dropoff
    from public.task_instances ti
    join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id
    left join public.profiles p on p.user_id=ti.planned_assignee_id
    where ti.household_id=p_household_id and ti.scheduled_date=v_day and ti.test_context_id is null
      and td.code='dropoff' and ti.status in ('todo','in_progress')
    limit 1;
    select regexp_replace(coalesce(p.display_name,'未定'), '（仮）$', '') into v_pickup
    from public.task_instances ti
    join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id
    left join public.profiles p on p.user_id=ti.planned_assignee_id
    where ti.household_id=p_household_id and ti.scheduled_date=v_day and ti.test_context_id is null
      and td.code='pickup' and ti.status in ('todo','in_progress')
    limit 1;

    select string_agg('・'||ti.title, E'\n' order by ti.due_at nulls last, ti.title) into v_special
    from public.task_instances ti
    where ti.household_id=p_household_id and ti.scheduled_date=v_day and ti.test_context_id is null
      and ti.calendar_visibility='special' and ti.status in ('todo','in_progress');

    begin v_cal := private.fn_calendar_day_lines(p_household_id, v_day);
    exception when others then v_cal := null; end;
    begin
  with manual_hl as (
    select
      '・' || ti.title
        || coalesce(' (期限' || to_char(ti.due_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || ')', '') as line,
      ti.due_at as sort_ts
    from public.task_instances ti
    where ti.household_id = p_household_id
      and ti.origin = 'manual'
      and (ti.calendar_visibility is distinct from 'special' or ti.scheduled_date <> v_day)
      and ti.status in ('todo', 'in_progress')
      and ti.due_at is not null
      and (ti.due_at at time zone 'Asia/Tokyo')::date between v_day and v_day

  ),
  request_hl as (
    select
      '・' || r.shared_title
        || coalesce(' (期限' || to_char(r.due_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || ')', '') as line,
      r.due_at as sort_ts
    from public.requests r
    where r.household_id = p_household_id
      and r.status in ('pending', 'accepted')
      and r.due_at is not null
      and (r.due_at at time zone 'Asia/Tokyo')::date between v_day and v_day
  ),
  shopping_hl as (
    select
      '・' || si.title
        || coalesce(' (期限' || to_char(si.due_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || ')', '') as line,
      si.due_at as sort_ts
    from public.shopping_items si
    where si.household_id = p_household_id
      and si.status in ('wanted', 'assigned', 'ordered')
      and si.due_at is not null
      and (si.due_at at time zone 'Asia/Tokyo')::date between v_day and v_day
  )
  select string_agg(line, E'\n' order by sort_ts, line)
  into v_hl
  from (
    select * from manual_hl
    union all
    select * from request_hl
    union all
    select * from shopping_hl
  ) x;
    exception when others then v_hl := null; end;

    v_cal := private.fn_weekly_preview_lines_v1(v_cal, v_special, v_hl, v_dropoff is not null or v_pickup is not null);

    if v_dropoff is null and v_pickup is null and v_cal is null then
      continue;
    end if;
    v_block := to_char(v_day,'FMMM/FMDD')||'('||(array['月','火','水','木','金','土','日'])[extract(isodow from v_day)::int]||')'
      || case when v_dropoff is not null or v_pickup is not null
           then E'\n送り '||coalesce(v_dropoff,'-')||' / 迎え '||coalesce(v_pickup,'-') else '' end
      || coalesce(E'\n'||v_cal,'');
    v_out := v_out || case when v_out='' then '' else E'\n\n' end || v_block;
  end loop;
  return nullif(v_out,'');
end;
$$;
revoke all on function private.fn_render_weekly_preview_v1(uuid, date) from public, anon, authenticated;
grant execute on function private.fn_render_weekly_preview_v1(uuid, date) to service_role;

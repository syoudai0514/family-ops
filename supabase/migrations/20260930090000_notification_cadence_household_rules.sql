-- Household notification cadence (owner decision, 2026-09-29).
--
--   * Workdays:  morning brief + evening brief, as before.
--   * Weekends and public holidays: ONE message only -- the morning brief.
--     No evening brief, no Codmon reminder.
--   * Sunday: that single morning message also carries next week's schedule
--     (Mon-Sun). The old Sunday weekly digest lived in the legacy routine
--     dispatcher, which the daily_brief_v2 gate has suppressed since
--     2026-09-04, so no weekly schedule has been sent since 2026-08-30.
--   * Codmon 09:00 reminder: to that day's pickup (迎え) assignee only.
--
-- It also seeds private.jp_holidays. Production had ZERO rows: the table is
-- only ever filled by the sync-jp-holidays worker, which has no cron entry, and
-- by scripts/seed_jp_holidays.mjs, which only CI runs. CI therefore tested
-- holiday behaviour production never had -- 2026-09-21..23 were treated as
-- workdays. The fixture below is the same checked-in Cabinet Office source the
-- CI seed uses; `do nothing` on conflict so a later real sync is never undone.

insert into private.jp_holidays (local_date, name, source, source_fetched_at)
values
  (date '2026-01-01', '元日', 'cao_csv', now()),
  (date '2026-01-12', '成人の日', 'cao_csv', now()),
  (date '2026-02-11', '建国記念の日', 'cao_csv', now()),
  (date '2026-02-23', '天皇誕生日', 'cao_csv', now()),
  (date '2026-03-20', '春分の日', 'cao_csv', now()),
  (date '2026-04-29', '昭和の日', 'cao_csv', now()),
  (date '2026-05-03', '憲法記念日', 'cao_csv', now()),
  (date '2026-05-04', 'みどりの日', 'cao_csv', now()),
  (date '2026-05-05', 'こどもの日', 'cao_csv', now()),
  (date '2026-05-06', '休日', 'cao_csv', now()),
  (date '2026-07-20', '海の日', 'cao_csv', now()),
  (date '2026-08-11', '山の日', 'cao_csv', now()),
  (date '2026-09-21', '敬老の日', 'cao_csv', now()),
  (date '2026-09-22', '休日', 'cao_csv', now()),
  (date '2026-09-23', '秋分の日', 'cao_csv', now()),
  (date '2026-10-12', 'スポーツの日', 'cao_csv', now()),
  (date '2026-11-03', '文化の日', 'cao_csv', now()),
  (date '2026-11-23', '勤労感謝の日', 'cao_csv', now()),
  (date '2027-01-01', '元日', 'cao_csv', now()),
  (date '2027-01-11', '成人の日', 'cao_csv', now()),
  (date '2027-02-11', '建国記念の日', 'cao_csv', now()),
  (date '2027-02-23', '天皇誕生日', 'cao_csv', now()),
  (date '2027-03-21', '春分の日', 'cao_csv', now()),
  (date '2027-03-22', '休日', 'cao_csv', now()),
  (date '2027-04-29', '昭和の日', 'cao_csv', now()),
  (date '2027-05-03', '憲法記念日', 'cao_csv', now()),
  (date '2027-05-04', 'みどりの日', 'cao_csv', now()),
  (date '2027-05-05', 'こどもの日', 'cao_csv', now()),
  (date '2027-07-19', '海の日', 'cao_csv', now()),
  (date '2027-08-11', '山の日', 'cao_csv', now()),
  (date '2027-09-20', '敬老の日', 'cao_csv', now()),
  (date '2027-09-23', '秋分の日', 'cao_csv', now()),
  (date '2027-10-11', 'スポーツの日', 'cao_csv', now()),
  (date '2027-11-03', '文化の日', 'cao_csv', now()),
  (date '2027-11-23', '勤労感謝の日', 'cao_csv', now())
on conflict (local_date) do nothing;

-- ---------------------------------------------------------------------------
-- 1. Evening brief on workdays only.
-- ---------------------------------------------------------------------------
create or replace function public.server_read_due_daily_brief_slots(
  p_now timestamptz default now()
) returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
declare
  v_date date := (p_now at time zone 'Asia/Tokyo')::date;
  v_nonworkday boolean := private.is_jp_nonworkday((p_now at time zone 'Asia/Tokyo')::date);
  v_result jsonb;
begin
  with candidate as (
    select h.id household_id, k.brief_kind, r.enabled, r.local_time, r.source
    from public.households h
    cross join lateral (values
      ('weekday_morning_brief'::text),
      ('nonworkday_morning_brief'::text),
      ('evening_brief'::text)
    ) k(brief_kind)
    cross join lateral private.resolve_daily_brief_schedule(h.id,v_date,k.brief_kind) r
    -- Weekends/holidays get exactly one message: the morning brief.
    where ((not v_nonworkday and k.brief_kind in ('weekday_morning_brief','evening_brief'))
      or (v_nonworkday and k.brief_kind='nonworkday_morning_brief'))
      and r.enabled and r.local_time is not null
  ), due as (
    select c.*, hm.user_id recipient_user_id,
      ((v_date+c.local_time)::timestamp at time zone 'Asia/Tokyo') scheduled_at,
      v_date::text||':'||c.brief_kind||':'||hm.user_id::text dispatch_slot_key
    from candidate c join public.household_members hm on hm.household_id=c.household_id
    where ((v_date+c.local_time)::timestamp at time zone 'Asia/Tokyo') <= p_now
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'household_id',d.household_id,'recipient_user_id',d.recipient_user_id,
    'schedule_kind',d.brief_kind,'local_date',v_date,'local_time',d.local_time,
    'scheduled_at',d.scheduled_at,'schedule_source',d.source,
    'dispatch_slot_key',d.dispatch_slot_key
  ) order by d.scheduled_at,d.household_id,d.recipient_user_id),'[]'::jsonb)
  into v_result from due d
  where not exists (
    select 1 from private.scheduled_dispatch_receipts s
    where s.household_id=d.household_id and s.schedule_kind=d.brief_kind
      and s.scheduled_local_date=v_date and s.recipient_user_id=d.recipient_user_id
  );
  return v_result;
end;
$$;
revoke all on function public.server_read_due_daily_brief_slots(timestamptz)
  from public, anon, authenticated;
grant execute on function public.server_read_due_daily_brief_slots(timestamptz)
  to service_role;

-- ---------------------------------------------------------------------------
-- 2. Next week's schedule, for the Sunday morning message.
--    Per day: 送迎 + Google Calendar + special (calendar-visible) tasks +
--    due requests/shopping/manual tasks. Ordinary daily chores are left out:
--    listing 朝ごはん seven times is noise, not a schedule.
-- ---------------------------------------------------------------------------
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
    select coalesce(p.display_name,'未定') into v_dropoff
    from public.task_instances ti
    join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id
    left join public.profiles p on p.user_id=ti.planned_assignee_id
    where ti.household_id=p_household_id and ti.scheduled_date=v_day and ti.test_context_id is null
      and td.code='dropoff' and ti.status in ('todo','in_progress')
    limit 1;
    select coalesce(p.display_name,'未定') into v_pickup
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
    begin v_hl := private.fn_due_highlight_lines(p_household_id, v_day, v_day, null);
    exception when others then v_hl := null; end;

    if v_dropoff is null and v_pickup is null and v_special is null and v_cal is null and v_hl is null then
      continue;
    end if;
    v_block := to_char(v_day,'FMMM/FMDD')||'('||(array['月','火','水','木','金','土','日'])[extract(isodow from v_day)::int]||')'
      || case when v_dropoff is not null or v_pickup is not null
           then E'\n送り '||coalesce(v_dropoff,'-')||' / 迎え '||coalesce(v_pickup,'-') else '' end
      || coalesce(E'\n'||v_cal,'')
      || coalesce(E'\n'||v_special,'')
      || coalesce(E'\n'||v_hl,'');
    v_out := v_out || case when v_out='' then '' else E'\n\n' end || v_block;
  end loop;
  return nullif(v_out,'');
end;
$$;
revoke all on function private.fn_render_weekly_preview_v1(uuid, date) from public, anon, authenticated;
grant execute on function private.fn_render_weekly_preview_v1(uuid, date) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Daily brief dispatch: Sunday's single message carries next week.
-- ---------------------------------------------------------------------------
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
  v_body text;
  v_week text;
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
    v_body := private.fn_render_daily_brief_text_v3(
      private.fn_daily_brief_for_line_v1(v_brief, r.recipient_user_id, r.scheduled_at, v_mode), v_mode);

    v_week := null;
    if r.schedule_kind='nonworkday_morning_brief' and extract(isodow from r.local_date)=7 then
      begin
        v_week := private.fn_render_weekly_preview_v1(r.household_id, r.local_date + 1);
      exception when others then
        v_week := null; -- never lose the morning brief over the preview
      end;
      v_body := v_body || E'\n\n📅 来週の予定' || E'\n' || coalesce(v_week, '（登録された予定はありません）');
    end if;
    v_body := left(v_body, 5000); -- LINE text message limit

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
      v_body,
      jsonb_build_object('brief',v_brief,'schedule_kind',r.schedule_kind,
        'weekly_preview', v_week is not null),
      v_dedup,
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

-- ---------------------------------------------------------------------------
-- 4. Codmon 09:00 reminder: one recipient, the day's pickup (迎え) assignee.
--    Because only one adult now receives it, the body lists every pending
--    input with its owner instead of "your inputs" -- otherwise inputs owned
--    by the other adult would silently disappear from the only reminder.
--    Fallbacks keep the 9:15 deadline covered when pickup is unassigned or
--    cancelled that day: the codmon_submit assignee, then every adult.
--    Weekends/holidays stay silent (fn_is_nonworkday, now with real holidays).
-- ---------------------------------------------------------------------------
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
  v_recipient uuid;
  v_recipients uuid[];
  v_readiness jsonb;
  v_pending text;
  v_body text;
  v_actor_ref uuid;
  v_inserted int := 0;
  v_dedup text;
begin
  if p_now is null then raise exception 'INVALID_INPUT'; end if;

  v_local_now := p_now at time zone 'Asia/Tokyo';
  v_local_date := v_local_now::date;

  if to_char(v_local_now, 'HH24:MI') <> '09:00' then
    return jsonb_build_object('due', false, 'local_date', v_local_date, 'notifications', 0);
  end if;
  if private.fn_is_nonworkday(v_local_date) then
    return jsonb_build_object('due', false, 'nonworkday', true, 'local_date', v_local_date, 'notifications', 0);
  end if;

  for v_household in
    select distinct ti.household_id
    from public.task_instances ti
    join public.task_definitions td on td.household_id = ti.household_id and td.id = ti.task_definition_id
    where ti.scheduled_date = v_local_date
      and ti.test_context_id is null
      and td.code = 'codmon_submit'
      and ti.status in ('todo', 'in_progress')
  loop
    v_readiness := private.fn_codmon_readiness_v1(v_household.household_id, v_local_date, null);

    -- Recipient: pickup assignee -> codmon_submit assignee -> every adult.
    select array_agg(x) into v_recipients from (
      select ti.planned_assignee_id x
      from public.task_instances ti
      join public.task_definitions td on td.household_id = ti.household_id and td.id = ti.task_definition_id
      where ti.household_id = v_household.household_id and ti.scheduled_date = v_local_date
        and ti.test_context_id is null and td.code = 'pickup'
        and ti.status in ('todo', 'in_progress') and ti.planned_assignee_id is not null
      limit 1
    ) s;
    if v_recipients is null then
      select array_agg(x) into v_recipients from (
        select ti.planned_assignee_id x
        from public.task_instances ti
        join public.task_definitions td on td.household_id = ti.household_id and td.id = ti.task_definition_id
        where ti.household_id = v_household.household_id and ti.scheduled_date = v_local_date
          and ti.test_context_id is null and td.code = 'codmon_submit'
          and ti.status in ('todo', 'in_progress') and ti.planned_assignee_id is not null
        limit 1
      ) s;
    end if;
    if v_recipients is null then
      select array_agg(hm.user_id order by hm.joined_at, hm.user_id) into v_recipients
      from public.household_members hm
      where hm.household_id = v_household.household_id and hm.member_role = 'adult';
    end if;

    v_body := null;
    if v_readiness->>'state' = 'waiting_inputs' then
      select string_agg(
        '・' || coalesce(i->>'title','入力')
          || coalesce('（' || coalesce(p.display_name, '担当未定') || '）', ''),
        E'\n' order by ord)
      into v_pending
      from jsonb_array_elements(coalesce(v_readiness->'inputs','[]'::jsonb)) with ordinality as e(i, ord)
      left join public.profiles p on p.user_id = nullif(i->>'assignee_user_id','')::uuid
      where i->>'resolution' = 'present' and coalesce(i->>'status','') <> 'completed';
      if v_pending is not null then
        v_body := '9:15までにコドモン送信が必要です。' || E'\n\nまだの入力:\n' || v_pending
          || E'\n\n入力がそろったら送信してください。';
      end if;
    elsif v_readiness->>'state' = 'ready_to_submit' then
      v_body := '入力がそろいました。9:15までにコドモンを送信してください。';
    elsif v_readiness->>'state' = 'data_incomplete' then
      v_body := 'コドモンの入力状況を確認できません。9:15までの送信前に、おうちノートを更新して入力状況を確認してください。';
    end if;
    if v_body is null then continue; end if;

    foreach v_recipient in array v_recipients loop
      select a.id into v_actor_ref
      from public.domain_actor_refs a
      where a.household_id = v_household.household_id and a.actor_kind = 'real_user'
        and a.real_user_id = v_recipient and a.test_context_id is null
      order by a.id limit 1;
      if v_actor_ref is null then continue; end if;

      v_dedup := 'codmon-deadline:' || v_household.household_id::text || ':'
        || v_recipient::text || ':' || v_local_date::text;

      insert into public.user_notifications(
        household_id, recipient_user_id, type, title, body, payload, dedup_key,
        recipient_actor_ref_id, notification_kind, urgency, safety_class,
        bundle_key, business_expires_at, aggregate_type, aggregate_revision, test_context_id
      ) values (
        v_household.household_id, v_recipient, 'codmon.deadline',
        '⏰ コドモン 9:15まで', v_body,
        jsonb_build_object('local_date', v_local_date, 'deadline', '09:15',
          'readiness_state', v_readiness->>'state', 'recipient_rule', 'pickup_assignee'),
        v_dedup, v_actor_ref, 'codmon.deadline', 'immediate', 'normal',
        'codmon:' || v_household.household_id::text || ':' || v_local_date::text,
        ((v_local_date::text || ' 09:15')::timestamp at time zone 'Asia/Tokyo'),
        'codmon_daily', 1, null
      )
      on conflict(recipient_user_id, dedup_key) do nothing;
      if found then v_inserted := v_inserted + 1; end if;
    end loop;
  end loop;

  return jsonb_build_object('due', true, 'local_date', v_local_date, 'notifications', v_inserted);
end;
$$;
revoke all on function public.server_tx_dispatch_codmon_reminders_v1(timestamptz)
  from public, anon, authenticated;
grant execute on function public.server_tx_dispatch_codmon_reminders_v1(timestamptz)
  to service_role;

-- ---------------------------------------------------------------------------
-- 5. LINE brief content (owner review 2026-09-29).
-- ---------------------------------------------------------------------------

-- What goes into a scheduled LINE brief, per recipient and send time.
--   * Handovers: only ones someone ELSE wrote, that the recipient has not
--     read, and that are new (last 24h) or explicitly need acknowledgement.
--     Live, the same 【言語通級】 note was repeated in every morning and
--     evening brief for two weeks -- to its own author too.
--   * Evening: nursery (Codmon) inputs whose deadline has passed are dropped,
--     and so are the partner's items whose time has passed.
--     At 20:30 "まだ残っていること: コドモン入力×3" is noise: the 9:15 window is
--     long gone and nothing can be done about it.
-- The PWA and the LINE "今日" reply keep the full brief.
create or replace function private.fn_daily_brief_for_line_v1(
  p_brief jsonb,
  p_recipient uuid,
  p_at timestamptz,
  p_mode text
) returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select p_brief
    || jsonb_build_object('active_infos', coalesce((
      select jsonb_agg(i order by o)
      from jsonb_array_elements(coalesce(p_brief->'active_infos','[]'::jsonb)) with ordinality x(i, o)
      join public.handovers h on h.id = nullif(i->>'handover_id','')::uuid
      where h.author_id is distinct from p_recipient
        and (h.created_at >= p_at - interval '24 hours' or coalesce(h.ack_policy,'none') = 'required')
        and not exists (select 1 from public.handover_reads hr
                        where hr.handover_id = h.id and hr.user_id = p_recipient)
    ), '[]'::jsonb))
    -- Evening: the partner's items whose time has passed are dropped too. Live,
    -- the 20:30 brief listed the partner's 07:00 朝ごはん / 送り as "相手の今日".
    || case when p_mode = 'evening' then jsonb_build_object('partner_summary',
         coalesce(p_brief->'partner_summary','{}'::jsonb) || jsonb_build_object('critical_items', coalesce((
           select jsonb_agg(c order by o)
           from jsonb_array_elements(coalesce(p_brief->'partner_summary'->'critical_items','[]'::jsonb)) with ordinality x(c, o)
           where coalesce(nullif(c->>'due_at','')::timestamptz >= p_at, true)
         ), '[]'::jsonb)))
       else '{}'::jsonb end
    || case when p_mode = 'evening' then jsonb_build_object('own_task_groups',
         coalesce(p_brief->'own_task_groups','{}'::jsonb) || jsonb_build_object(
           'morning', coalesce((
             select jsonb_agg(t order by o)
             from jsonb_array_elements(coalesce(p_brief->'own_task_groups'->'morning','[]'::jsonb)) with ordinality x(t, o)
             where not (t->>'category' = 'nursery' and nullif(t->>'due_at','')::timestamptz < p_at)
           ), '[]'::jsonb)))
       else '{}'::jsonb end;
$$;
revoke all on function private.fn_daily_brief_for_line_v1(jsonb, uuid, timestamptz, text) from public, anon, authenticated;
grant execute on function private.fn_daily_brief_for_line_v1(jsonb, uuid, timestamptz, text) to service_role;

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

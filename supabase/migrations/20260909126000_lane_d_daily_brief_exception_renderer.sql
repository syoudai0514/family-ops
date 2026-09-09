-- Lane D CF-02 / CF-04 closeout.
-- Preserve one canonical DailyBrief semantic snapshot while making the text
-- transport surface the same material exception/waiting/completion information
-- that PWA Today consumes. This is presentation only; no business state is
-- reconstructed here.

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
  elsif v_mode = 'evening' then
    v_part := private.fn_daily_brief_lines_v1(p_brief->'waiting_checks');
    if v_part is not null then v_text := v_text || E'\n\n待ち・確認\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(
      coalesce(p_brief->'own_task_groups'->'morning', '[]'::jsonb)
      || coalesce(p_brief->'own_task_groups'->'daytime', '[]'::jsonb)
      || coalesce(p_brief->'own_task_groups'->'evening', '[]'::jsonb)
    );
    if v_part is not null then v_text := v_text || E'\n\nまだ残っていること\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'active_infos');
    if v_part is not null then v_text := v_text || E'\n\n引き継ぎ・共有\n' || v_part; end if;
    if v_morning_total > 0 then
      v_text := v_text || E'\n\n朝のまとめ\n・朝 ' || v_morning_completed::text || '/' || v_morning_total::text || ' 完了';
    end if;
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
    if v_part is not null then v_text := v_text || E'\n\n引き継ぎ・共有\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'already_handled');
    if v_part is not null then v_text := v_text || E'\n\nもう済んでいる\n' || v_part; end if;
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
  return private.fn_render_daily_brief_text_v3(
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
      private.fn_render_daily_brief_text_v3(v_brief, v_mode),
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

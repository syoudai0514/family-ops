-- User-facing family setup. No provider sends, capability changes, or data resets.
-- All writes are household-scoped and receipt-backed; private LINE identifiers stay private.
create or replace function public.server_read_family_setup(p_actor_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_household uuid;
begin
  select household_id into v_household from public.household_members where user_id=p_actor_id;
  if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  return jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object('user_id',hm.user_id,
      'line_linked',coalesce(l.status='active',false),'line_linked_at',case when l.status='active' then l.linked_at end))
      from public.household_members hm left join private.line_user_links l
      on l.household_id=hm.household_id and l.user_id=hm.user_id where hm.household_id=v_household),'[]'::jsonb),
    'children',coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at) from public.family_children c where c.household_id=v_household),'[]'::jsonb),
    'contexts',coalesce((select jsonb_agg(to_jsonb(c) order by c.effective_from desc) from public.child_school_contexts c where c.household_id=v_household),'[]'::jsonb));
end $$;
revoke all on function public.server_read_family_setup(uuid) from public,anon,authenticated;
grant execute on function public.server_read_family_setup(uuid) to service_role;

create or replace function private.fn_command_family_setup_v1(p_actor_id uuid,p_operation_id uuid,p_action text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_household uuid; v_hash text; v_receipt record; v_result jsonb;
  v_child uuid; v_context uuid; v_name text; v_school text; v_class text;
  v_from date; v_to date; v_aliases text[];
begin
  if p_actor_id is null or p_operation_id is null or p_action is null
    or p_action not in ('save_context','finish_later','reissue_invite')
    or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'INVALID_INPUT'; end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id;
  if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  -- Serialize household setup changes, including invite recovery.
  perform 1 from public.households where id=v_household for update;
  v_hash:=encode(sha256(convert_to(jsonb_build_object('action',p_action,'payload',p_payload)::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
  values(p_actor_id,p_operation_id,'family-setup:'||p_action,v_hash) on conflict(actor_id,operation_id) do nothing;
  if not found then
    select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash is distinct from v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    if p_action='reissue_invite' then raise exception 'INVITE_TOKEN_ALREADY_ISSUED'; end if;
    return v_receipt.result_payload;
  end if;
  if p_action='finish_later' then
    update public.households set
      dropoff_pickup_setup_completed_at=coalesce(dropoff_pickup_setup_completed_at,now()),
      evening_routine_setup_completed_at=coalesce(evening_routine_setup_completed_at,now()),
      morning_preparation_setup_completed_at=coalesce(morning_preparation_setup_completed_at,now()),
      connections_setup_completed_at=coalesce(connections_setup_completed_at,now()),
      notification_preferences_setup_completed_at=coalesce(notification_preferences_setup_completed_at,now()),
      onboarding_preview_completed_at=coalesce(onboarding_preview_completed_at,now())
      where id=v_household;
    v_result:=jsonb_build_object('household_id',v_household,'completed',true);
  elsif p_action='reissue_invite' then
    if (select count(*) from public.household_members where household_id=v_household and member_role='adult')>=2 then
      raise exception 'HOUSEHOLD_FULL'; end if;
    update private.household_invites set expires_at=least(expires_at,now()) where household_id=v_household and used_at is null;
    -- The canonical invite command retains its own receipt. Use a distinct ID
    -- so its claim cannot collide with this recovery operation's receipt.
    v_result:=public.server_tx_create_household_invite(p_actor_id,gen_random_uuid());
  else
    v_child:=nullif(p_payload->>'child_id','')::uuid;
    v_context:=nullif(p_payload->>'context_id','')::uuid;
    v_name:=btrim(p_payload->>'display_name'); v_school:=btrim(p_payload->>'school_display_name');
    v_class:=nullif(btrim(p_payload->>'class_display_name'),'');
    v_from:=nullif(p_payload->>'effective_from','')::date; v_to:=nullif(p_payload->>'effective_to','')::date;
    if v_name is null or length(v_name) not between 1 and 120 or v_school is null or length(v_school) not between 1 and 120
      or length(coalesce(v_class,''))>120 or v_from is null or v_to<v_from
      or jsonb_typeof(coalesce(p_payload->'recognition_aliases','[]'::jsonb))<>'array' then raise exception 'INVALID_INPUT'; end if;
    select coalesce(array_agg(btrim(value)), '{}'::text[]) into v_aliases
      from jsonb_array_elements_text(coalesce(p_payload->'recognition_aliases','[]'::jsonb));
    if cardinality(v_aliases)>20 or exists(select 1 from unnest(v_aliases) a where length(a) not between 1 and 120) then raise exception 'INVALID_INPUT'; end if;
    if v_child is null then
      if v_context is not null then raise exception 'INVALID_INPUT'; end if;
      insert into public.family_children(household_id,display_name) values(v_household,v_name) returning id into v_child;
    else
      update public.family_children set display_name=v_name where household_id=v_household and id=v_child;
      if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
    end if;
    if v_context is null then
      insert into public.child_school_contexts(household_id,child_id,school_display_name,class_display_name,effective_from,effective_to,recognition_aliases)
      values(v_household,v_child,v_school,v_class,v_from,v_to,v_aliases) returning id into v_context;
    else
      update public.child_school_contexts set school_display_name=v_school,class_display_name=v_class,
        effective_from=v_from,effective_to=v_to,recognition_aliases=v_aliases
        where household_id=v_household and id=v_context and child_id=v_child;
      if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
    end if;
    v_result:=jsonb_build_object('child_id',v_child,'context_id',v_context);
  end if;
  update private.mutation_receipts set result_type='household',result_id=v_household,result_payload=case when p_action='reissue_invite' then v_result-'raw_token'-'expires_at' else v_result end
    where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end $$;
revoke all on function private.fn_command_family_setup_v1(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function private.fn_command_family_setup_v1(uuid,uuid,text,jsonb) to service_role;
create or replace function public.server_tx_family_setup(p_actor_id uuid,p_operation_id uuid,p_action text,p_payload jsonb)
returns jsonb language sql security invoker set search_path = '' as $$
  select private.fn_command_family_setup_v1(p_actor_id,p_operation_id,p_action,p_payload)
$$;
revoke all on function public.server_tx_family_setup(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_family_setup(uuid,uuid,text,jsonb) to service_role;

-- Keep PWA task order intact. Only add a marker using the scheduled LINE
-- classifier, including its weekend/holiday policy and effective-date rules.
create or replace function public.get_my_daily_brief(p_local_date date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_brief jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.fn_capability_reader_enabled_v1('daily_brief_v2') then raise exception 'CAPABILITY_READER_NOT_ENABLED:daily_brief_v2'; end if;
  v_brief:=public.server_read_daily_brief(auth.uid(),p_local_date);
  return v_brief || jsonb_build_object('special_today',private.fn_brief_split_special_v1(v_brief)->'special_today');
end $$;
revoke all on function public.get_my_daily_brief(date) from public,anon;
grant execute on function public.get_my_daily_brief(date) to authenticated;

-- A confirmation preview reads the exact agreed target snapshot. It does not
-- reconstruct "this week" on the client or change any assignments.
create or replace function public.server_read_assignment_preview(p_actor_id uuid,p_request_id uuid,p_attempt_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_household uuid; r public.requests%rowtype; a public.request_attempts%rowtype; v_targets jsonb; v_linked jsonb; v_stale boolean;
begin
  select household_id into v_household from public.household_members where user_id=p_actor_id;
  if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select * into r from public.requests where household_id=v_household and id=p_request_id and test_context_id is null;
  if not found or p_actor_id not in (r.requester_id,r.recipient_id) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  select * into a from public.request_attempts where household_id=v_household and id=p_attempt_id and request_id=r.id and test_context_id is null;
  if not found or jsonb_typeof(a.terms->'assignment_targets') is distinct from 'array' then raise exception 'INVALID_INPUT'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'title',t.title,'date',t.scheduled_date,'due_at',t.due_at,
      'from_user_id',t.planned_assignee_id,'to_user_id',r.recipient_id) order by t.scheduled_date,t.due_at),'[]'::jsonb),
    coalesce(bool_or(t.revision is distinct from (x->>'revision')::bigint
      or t.planned_assignee_actor_ref_id is distinct from (x->>'assignee_actor_ref_id')::uuid or t.status not in ('todo','in_progress')),true)
    into v_targets,v_stale from jsonb_array_elements(a.terms->'assignment_targets') x
    join public.task_instances t on t.household_id=v_household and t.id=(x->>'task_id')::uuid and t.test_context_id is null;
  v_stale:=v_stale or jsonb_array_length(v_targets)<>jsonb_array_length(a.terms->'assignment_targets');
  with anchors as (
    select t.scheduled_date,d.code from jsonb_array_elements(a.terms->'assignment_targets') x
    join public.task_instances t on t.household_id=v_household and t.id=(x->>'task_id')::uuid and t.test_context_id is null
    join public.task_definitions d on d.household_id=v_household and d.id=t.task_definition_id and d.code in ('pickup','dropoff')
  ), linked as (
    select distinct t.id,t.title,t.scheduled_date,t.due_at,t.planned_assignee_id,
      case when rr.assignee_strategy='nonpickup_adult' then (select hm.user_id from public.household_members hm
        where hm.household_id=v_household and hm.member_role='adult' and hm.user_id<>r.recipient_id order by hm.user_id limit 1)
      else r.recipient_id end as to_user_id
    from anchors an join public.task_instances t on t.household_id=v_household and t.scheduled_date=an.scheduled_date
    join public.recurrence_rules rr on rr.household_id=v_household and rr.id=t.recurrence_rule_id
    where t.test_context_id is null and t.status in ('todo','in_progress')
      and coalesce(t.assignment_source,'legacy_snapshot')='legacy_snapshot' and t.active_claimant_actor_ref_id is null
      and not (coalesce(t.source_context,'{}'::jsonb) ? 'transport_occurrence_override')
      and ((an.code='pickup' and rr.assignee_strategy in ('pickup_assignee','nonpickup_adult')) or (an.code='dropoff' and rr.assignee_strategy='dropoff_assignee'))
      and not exists(select 1 from public.task_events e where e.household_id=v_household and e.task_instance_id=t.id and e.event_type in ('assignment_agreed','reassigned_once','cancelled'))
  ) select coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title,'date',scheduled_date,'due_at',due_at,
    'from_user_id',planned_assignee_id,'to_user_id',to_user_id) order by scheduled_date,due_at),'[]'::jsonb) into v_linked from linked where planned_assignee_id is distinct from to_user_id;
  return jsonb_build_object('targets',v_targets,'linked',v_linked,'stale',v_stale,'revision',a.revision,'terms_revision',a.terms_revision);
end $$;
revoke all on function public.server_read_assignment_preview(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_read_assignment_preview(uuid,uuid,uuid) to service_role;

-- Stable schedule location and shared vocabulary in scheduled LINE briefs.
create or replace function private.fn_render_daily_brief_text_v4(
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


  v_part := private.fn_daily_brief_lines_v1(p_brief->'schedule');
  if v_part is not null then v_text := v_text || E'\n\n今日の予定\n' || v_part; end if;

  if v_mode = 'morning' then
    v_part := private.fn_daily_brief_lines_v1(p_brief->'already_handled');
    if v_part is not null then v_text := v_text || E'\n\nもう済んでいる\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'waiting_checks');
    if v_part is not null then v_text := v_text || E'\n\n待ち・確認\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'morning');
    if v_part is not null then v_text := v_text || E'\n\n朝やること\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'daytime');
    if v_part is not null then v_text := v_text || E'\n\n日中にやること\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'evening');
    if v_part is not null then v_text := v_text || E'\n\n夜にやること\n' || v_part; end if;
  elsif v_mode = 'evening' then
    v_part := private.fn_daily_brief_lines_v1(p_brief->'waiting_checks');
    if v_part is not null then v_text := v_text || E'\n\n待ち・確認\n' || v_part; end if;
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
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'morning');
    if v_part is not null then v_text := v_text || E'\n\n朝の残り\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'daytime');
    if v_part is not null then v_text := v_text || E'\n\n今やること\n' || v_part; end if;
    v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'evening');
    if v_part is not null then v_text := v_text || E'\n\nこのあと（夜）\n' || v_part; end if;
  end if;

  v_part := private.fn_daily_brief_handover_lines_v1(p_brief->'active_infos');
  if v_part is not null then v_text := v_text || E'\n\n引き継ぎ・共有\n' || v_part; end if;

  v_part := private.fn_daily_brief_lines_v1(p_brief->'own_task_groups'->'optional');
  if v_part is not null then v_text := v_text || E'\n\n余裕があれば\n' || v_part; end if;

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
    v_text := v_text || E'\n\n朝・夜の記録\n・未確認 '
      || (p_brief#>>'{reconciliation,remaining_count}') || '件';
  end if;

  if v_mode = 'evening' then
    v_part := private.fn_daily_brief_lines_v1(p_brief->'shopping');
    if v_part is not null then v_text := v_text || E'\n\n買い物\n' || v_part; end if;
  end if;

  return left(v_text, 5000);
end;
$$;

revoke all on function private.fn_render_daily_brief_text_v4(jsonb, text) from public, anon, authenticated;
grant execute on function private.fn_render_daily_brief_text_v4(jsonb, text) to service_role;

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
    v_body := private.fn_render_daily_brief_text_v4(
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

-- Receipt-backed compare-and-set for a recorded outcome and its immediate undo.
-- v1 remains available to older PWA and LINE callers.
create or replace function public.server_tx_mark_task_could_not_do_v2(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_expected_revision bigint,
  p_undo boolean default false,
  p_source text default 'pwa'
)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_request_hash text;
  v_receipt private.mutation_receipts%rowtype;
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref uuid;
  v_task public.task_instances%rowtype;
  v_new_revision bigint;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null or p_undo is null
     or p_expected_revision is null or p_expected_revision < 1
     or p_source not in ('pwa','line') then
    raise exception 'INVALID_INPUT';
  end if;

  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  v_actor_ref:=(v_context->>'actor_ref_id')::uuid;

  v_request_hash:=encode(sha256(convert_to(
    'task-could-not-do-v2|'||p_task_id::text||'|'||p_expected_revision::text||'|'||p_undo::text||'|'||p_source,'UTF8')),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash,actor_ref_id)
      values(p_actor_id,p_operation_id,'task-could-not-do-v2',v_request_hash,v_actor_ref)
      on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
      where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if found then
      if v_receipt.action_type<>'task-could-not-do-v2' or v_receipt.request_hash<>v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select * into v_task from public.task_instances
  where household_id=v_household_id and id=p_task_id and test_context_id is null
  for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_task.revision <> p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;

  if not p_undo then
    if v_task.status not in ('todo','in_progress') then raise exception 'TASK_TERMINAL'; end if;
    update public.task_instances set
      status='skipped',outcome_reason='could_not_do',rescheduled_to=null,
      completed_at=null,actual_completed_by_id=null,
      attention_state='active',waiting_note=null,next_check_at=null,
      active_claimant_actor_ref_id=null,claimed_at=null,
      revision=revision+1
    where household_id=v_household_id and id=p_task_id
    returning revision into v_new_revision;
    insert into public.task_events(
      household_id,task_instance_id,actor_id,actor_ref_id,event_type,payload,source,idempotency_key
    ) values(
      v_household_id,p_task_id,p_actor_id,v_actor_ref,'skipped',
      jsonb_build_object('outcome_reason','could_not_do','previous_status',v_task.status),
      p_source,p_operation_id::text||':could-not-do'
    );
    v_result:=jsonb_build_object('ok',true,'task_id',p_task_id,'status','skipped',
      'outcome_reason','could_not_do','revision',v_new_revision,'title',v_task.title);
  else
    if v_task.status<>'skipped' or v_task.outcome_reason is distinct from 'could_not_do' then
      raise exception 'TASK_NOT_COULD_NOT_DO';
    end if;
    update public.task_instances set
      status='todo',outcome_reason=null,revision=revision+1
    where household_id=v_household_id and id=p_task_id
    returning revision into v_new_revision;
    insert into public.task_events(
      household_id,task_instance_id,actor_id,actor_ref_id,event_type,payload,source,idempotency_key
    ) values(
      v_household_id,p_task_id,p_actor_id,v_actor_ref,'could_not_do_reverted',
      jsonb_build_object('reason','mistap_or_correction'),
      p_source,p_operation_id::text||':could-not-do-reverted'
    );
    v_result:=jsonb_build_object('ok',true,'task_id',p_task_id,'status','todo',
      'revision',v_new_revision,'title',v_task.title);
  end if;

  update private.mutation_receipts set
    result_type='task_instance',result_id=p_task_id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;

revoke all on function public.server_tx_mark_task_could_not_do_v2(uuid,uuid,uuid,bigint,boolean,text)
  from public,anon,authenticated;
grant execute on function public.server_tx_mark_task_could_not_do_v2(uuid,uuid,uuid,bigint,boolean,text)
  to service_role;

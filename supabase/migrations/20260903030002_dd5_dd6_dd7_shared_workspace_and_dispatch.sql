-- WP-DD5/DD6/DD7 shared read semantics and inactive dispatch cutover source.
-- Capability rows default R0 + mutation paused, so applying this source alone
-- cannot activate the new production dispatcher or cross P1.

create table private.canonical_capability_gates (
  capability text primary key,
  release_stage text not null default 'R0' check (release_stage in ('R0','R1','P1')),
  reader_enabled boolean not null default false,
  writer_enabled boolean not null default false,
  mutation_paused boolean not null default true,
  p1_crossed_at timestamptz null,
  updated_at timestamptz not null default now(),
  check ((release_stage='P1') = (p1_crossed_at is not null)),
  check (release_stage<>'R0' or (not reader_enabled and not writer_enabled))
);
revoke all on private.canonical_capability_gates from public,anon,authenticated;
grant select,insert,update,delete on private.canonical_capability_gates to service_role;
insert into private.canonical_capability_gates (capability) values
  ('request_negotiation_v2'),('actual_reconciliation_v2'),
  ('shopping_responsibility_v2'),('daily_brief_v2'),
  ('notification_policy_v2'),('family_event_authority_v1'),
  ('nursery_intake_v1'),('one_user_simulation_v1')
on conflict (capability) do nothing;

create or replace function private.fn_line_preference_column_for_type(p_type text)
returns text language sql immutable set search_path='' as $$
  select case p_type
    when 'request_received' then 'request_line'
    when 'request_accepted' then 'request_line'
    when 'request_declined' then 'request_line'
    when 'handover_created' then 'handover_line'
    when 'request.received' then 'request_line'
    when 'request.checking' then 'request_line'
    when 'request.accepted' then 'request_line'
    when 'request.declined' then 'request_line'
    when 'request.cancelled' then 'request_line'
    when 'request.followup_requested' then 'request_line'
    when 'request.followup_declined' then 'request_line'
    when 'task.completed_neutral' then 'routine_completion_line'
    when 'shopping.handled_neutral' then 'shopping_minor_line'
    when 'shopping.reopened_neutral' then 'shopping_minor_line'
    when 'daily_brief.v2' then 'daily_assignment_line'
    else null
  end;
$$;
revoke all on function private.fn_line_preference_column_for_type(text) from public,anon,authenticated;
grant execute on function private.fn_line_preference_column_for_type(text) to service_role;

create or replace function public.server_read_shopping_workspace(p_actor_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare v_household_id uuid; v_actor_ref_id uuid; v_active jsonb; v_history jsonb;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;
  select household_id into v_household_id from public.household_members where user_id=p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select id into v_actor_ref_id from public.domain_actor_refs
    where household_id=v_household_id and actor_kind='real_user' and real_user_id=p_actor_id;
  with shaped as (
    select si.*,
      jsonb_build_object(
        'shopping_item_id',si.id,'title',si.title,'purchase_method',si.purchase_method,
        'status',si.status,'url',si.url,'due_at',si.due_at,
        'assignment_mode',coalesce(si.assignment_mode,case when si.assignee_id is null then 'unassigned' else 'person' end),
        'assignee_id',si.assignee_id,'assignee_actor_ref_id',si.assignee_actor_ref_id,
        'active_claimant_actor_ref_id',si.active_claimant_actor_ref_id,'claimed_at',si.claimed_at,
        'duplicate_sensitivity',coalesce(si.duplicate_sensitivity,'normal'),
        'performer_count',coalesce(actuals.performer_count,0),
        'performers',coalesce(actuals.performers,'[]'::jsonb),
        'household_completion_units',case when si.status in ('ordered','purchased','arrived') then 1 else 0 end,
        'revision',si.revision,
        'can_claim',coalesce(si.assignment_mode='anyone' and si.status='wanted' and si.active_claimant_actor_ref_id is null,false),
        'can_release',coalesce(si.active_claimant_actor_ref_id=v_actor_ref_id,false),
        'can_takeover',coalesce(si.assignment_mode='anyone' and si.status='wanted' and si.active_claimant_actor_ref_id<>v_actor_ref_id,false),
        'action_target',jsonb_build_object('kind','shopping','shopping_item_id',si.id,'revision',si.revision)
      ) item
    from public.shopping_items si
    left join lateral (
      select count(distinct sap.actor_ref_id)::int performer_count,
        jsonb_agg(jsonb_build_object(
          'actor_ref_id',sap.actor_ref_id,'real_user_id',ar.real_user_id,
          'actor_kind',ar.actor_kind,'simulated_role',ar.simulated_role,
          'action_kind',sap.action_kind,'recorded_at',sap.created_at,
          'recorded_by_actor_ref_id',sap.recorded_by_actor_ref_id
        ) order by sap.created_at,sap.id) performers
      from public.shopping_actual_participants sap
      join public.domain_actor_refs ar on ar.household_id=sap.household_id and ar.id=sap.actor_ref_id
      where sap.household_id=si.household_id and sap.shopping_item_id=si.id
        and sap.test_context_id is null and sap.removed_at is null
    ) actuals on true
    where si.household_id=v_household_id and si.test_context_id is null
  )
  select
    coalesce(jsonb_agg(item order by due_at nulls last,created_at)
      filter(where status in ('wanted','assigned','ordered')),'[]'::jsonb),
    coalesce(jsonb_agg(item order by coalesce(arrived_at,purchased_at,ordered_at,created_at) desc)
      filter(where status in ('purchased','arrived','cancelled')),'[]'::jsonb)
  into v_active,v_history from shaped;
  return jsonb_build_object('generated_at',now(),'household_id',v_household_id,
    'actor_ref_id',v_actor_ref_id,'active',v_active,'history',v_history,
    'writer_state','canonical_v1');
end; $$;

create or replace function public.server_read_daily_brief(
  p_actor_id uuid,p_local_date date default null
) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare
  v_household_id uuid; v_actor_ref_id uuid;
  v_date date:=coalesce(p_local_date,(now() at time zone 'Asia/Tokyo')::date);
  v_day_end timestamptz:=((coalesce(p_local_date,(now() at time zone 'Asia/Tokyo')::date)+1)::timestamp at time zone 'Asia/Tokyo');
  v_tasks jsonb; v_requests jsonb; v_waiting jsonb; v_carryover jsonb;
  v_handovers jsonb; v_handled jsonb; v_schedule jsonb; v_shopping jsonb; v_partner jsonb;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;
  select household_id into v_household_id from public.household_members where user_id=p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select id into v_actor_ref_id from public.domain_actor_refs
    where household_id=v_household_id and actor_kind='real_user' and real_user_id=p_actor_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',t.id,'title',t.title,'status',t.status,'task_kind',t.task_kind,
    'category',t.category,'routine_phase',t.routine_phase,'scheduled_date',t.scheduled_date,
    'due_at',t.due_at,'planned_assignee_id',t.planned_assignee_id,
    'planned_assignee_actor_ref_id',t.planned_assignee_actor_ref_id,
    'assignment_mode',coalesce(t.assignment_mode,case when t.planned_assignee_id is null then 'unassigned' else 'person' end),
    'completion_mode',t.completion_mode,'expectation',coalesce(t.expectation,'normal'),
    'duplicate_sensitivity',coalesce(t.duplicate_sensitivity,'normal'),'revision',t.revision,
    'action_target',jsonb_build_object('kind','task','task_id',t.id,'revision',t.revision)
  ) order by t.due_at nulls last,t.title),'[]'::jsonb) into v_tasks
  from public.task_instances t where t.household_id=v_household_id and t.test_context_id is null
    and t.scheduled_date=v_date and t.status in ('todo','in_progress') and t.attention_state='active'
    and ((t.planned_assignee_actor_ref_id=v_actor_ref_id)
      or (t.planned_assignee_actor_ref_id is null and t.planned_assignee_id=p_actor_id)
      or t.active_claimant_actor_ref_id=v_actor_ref_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',t.id,'title',t.title,'scheduled_date',t.scheduled_date,'due_at',t.due_at,
    'carryover_policy',t.carryover_policy,'result_certainty','unknown','semantic_result','result_unconfirmed',
    'revision',t.revision
  ) order by t.due_at nulls last,t.scheduled_date),'[]'::jsonb) into v_carryover
  from public.task_instances t where t.household_id=v_household_id and t.test_context_id is null
    and t.scheduled_date<v_date and t.status in ('todo','in_progress')
    and t.attention_state='active' and t.carryover_policy in ('until_done','until_deadline')
    and (t.carryover_policy<>'until_deadline' or t.due_at is null or t.due_at>=((v_date)::timestamp at time zone 'Asia/Tokyo'))
    and ((t.planned_assignee_actor_ref_id=v_actor_ref_id)
      or (t.planned_assignee_actor_ref_id is null and t.planned_assignee_id=p_actor_id)
      or t.active_claimant_actor_ref_id=v_actor_ref_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'request_id',r.id,'attempt_id',a.id,'attempt_kind',a.attempt_kind,'state',a.state,
    'title',r.shared_title,'message',r.shared_message,'reply_due_at',a.reply_due_at,
    'agreement_established',agreement.id is not null,'request_revision',r.revision,
    'revision',a.revision,'terms_revision',a.terms_revision,
    'action_target',jsonb_build_object('kind','request','request_id',r.id,
      'attempt_id',a.id,'revision',a.revision,'terms_revision',a.terms_revision)
  ) order by a.reply_due_at nulls last,a.created_at),'[]'::jsonb) into v_requests
  from public.requests r
  join lateral (
    select x.* from public.request_attempts x
    where x.household_id=r.household_id and x.request_id=r.id and x.test_context_id is null
      and x.state in ('pending','checking','consulting','awaiting_confirmation')
    order by x.created_at desc limit 1
  ) a on true
  left join lateral (
    select x.id from public.request_attempts x
    where x.request_id=r.id and x.attempt_kind in ('initial','reproposal') and x.state='accepted'
    limit 1
  ) agreement on true
  where r.household_id=v_household_id and r.test_context_id is null
    and v_actor_ref_id in (r.requester_actor_ref_id,r.recipient_actor_ref_id)
    and not exists (select 1 from public.request_attempt_confirmations c
      where c.attempt_id=a.id and c.terms_revision=a.terms_revision and c.actor_ref_id=v_actor_ref_id)
    and (
      (a.attempt_kind in ('initial','reproposal') and r.recipient_actor_ref_id=v_actor_ref_id)
      or (a.attempt_kind in ('change','cancel') and a.created_by_actor_ref_id<>v_actor_ref_id)
    );

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',t.id,'title',t.title,'waiting_note',t.waiting_note,'next_check_at',t.next_check_at,
    'due_at',t.due_at,'hard_due_risk',t.due_at is not null and t.due_at<v_day_end,'revision',t.revision
  ) order by t.next_check_at nulls last,t.due_at nulls last),'[]'::jsonb) into v_waiting
  from public.task_instances t where t.household_id=v_household_id and t.test_context_id is null
    and t.status in ('todo','in_progress') and t.attention_state='waiting'
    and (t.next_check_at is not null and t.next_check_at<v_day_end
      or t.due_at is not null and t.due_at<v_day_end)
    and ((t.planned_assignee_actor_ref_id=v_actor_ref_id)
      or (t.planned_assignee_actor_ref_id is null and t.planned_assignee_id=p_actor_id)
      or t.active_claimant_actor_ref_id=v_actor_ref_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'handover_id',h.id,'shared_text',h.shared_text,'period',h.period,'categories',h.categories,
    'valid_until',h.valid_until,'ack_policy',h.ack_policy,'revision',h.revision
  ) order by h.created_at desc),'[]'::jsonb) into v_handovers
  from public.handovers h where h.household_id=v_household_id and h.test_context_id is null
    and h.status='active' and h.visibility='household'
    and h.valid_from<v_day_end and (h.valid_until is null or h.valid_until>=((v_date)::timestamp at time zone 'Asia/Tokyo'))
    and not exists (select 1 from public.info_acknowledgements a
      where a.handover_id=h.id and a.actor_ref_id=v_actor_ref_id and a.test_context_id is null);

  select coalesce(jsonb_agg(jsonb_build_object(
    'kind','task','task_id',t.id,'title',t.title,'completed_at',t.completed_at,
    'duplicate_sensitivity',t.duplicate_sensitivity,'revision',t.revision
  ) order by t.completed_at desc),'[]'::jsonb) into v_handled
  from public.task_instances t where t.household_id=v_household_id and t.test_context_id is null
    and t.scheduled_date=v_date and t.status='completed'
    and t.duplicate_sensitivity in ('avoid_duplicate','safety_critical');

  select coalesce(jsonb_agg(x.item order by x.sort_key,x.title),'[]'::jsonb) into v_schedule
  from (
    select case when e.all_day then 0 else 1 end sort_key,e.title,
      jsonb_build_object('kind','family_event','family_event_id',e.id,'title',e.title,
        'is_all_day',e.all_day,
        'starts_at',case when e.all_day then 'null'::jsonb else to_jsonb(e.starts_at) end,
        'ends_at',case when e.all_day then 'null'::jsonb else to_jsonb(e.ends_at) end,
        'all_day_start',e.starts_on,'all_day_end_exclusive',case when e.all_day then e.ends_on+1 else null end,
        'revision',e.revision) item
    from public.family_events e where e.household_id=v_household_id and e.test_context_id is null
      and e.status<>'cancelled' and ((e.all_day and e.starts_on<=v_date and e.ends_on>=v_date)
        or (not e.all_day and (e.starts_at at time zone 'Asia/Tokyo')::date=v_date))
    union all
    select case when o.all_day_start is not null then 0 else 1 end,coalesce(o.title,''),
      jsonb_build_object('kind','google_occurrence','occurrence_key',o.occurrence_key,'title',o.title,
        'is_all_day',o.all_day_start is not null,
        'starts_at',case when o.all_day_start is null then to_jsonb(o.starts_at) else 'null'::jsonb end,
        'ends_at',case when o.all_day_start is null then to_jsonb(o.ends_at) else 'null'::jsonb end,
        'all_day_start',o.all_day_start,'all_day_end_exclusive',o.all_day_end_exclusive)
    from public.calendar_event_occurrences o
    join public.calendar_connections c on c.household_id=o.household_id and c.id=o.calendar_connection_id
    where o.household_id=v_household_id and c.active and o.status<>'cancelled'
      and coalesce(o.transparency,'opaque')<>'transparent'
      and ((o.all_day_start is not null and o.all_day_start<=v_date
          and coalesce(o.all_day_end_exclusive,o.all_day_start+1)>v_date)
        or (o.all_day_start is null and o.starts_at is not null
          and (o.starts_at at time zone 'Asia/Tokyo')::date=v_date))
      and not exists (select 1 from public.family_event_external_links l
        where l.household_id=v_household_id and l.calendar_connection_id=o.calendar_connection_id
          and l.google_event_id=o.google_event_id and l.test_context_id is null)
  ) x;

  v_shopping:=public.server_read_shopping_workspace(p_actor_id)->'active';
  select jsonb_build_object(
    'open_assigned',count(*) filter(where t.status in ('todo','in_progress')),
    'completed_today',count(*) filter(where t.status='completed' and t.scheduled_date=v_date)
  ) into v_partner from public.task_instances t
  where t.household_id=v_household_id and t.test_context_id is null
    and t.planned_assignee_actor_ref_id is distinct from v_actor_ref_id
    and t.planned_assignee_actor_ref_id is not null
    and (
      (t.status in ('todo','in_progress') and t.scheduled_date=v_date)
      or (t.status='completed' and t.scheduled_date=v_date)
    );

  return jsonb_build_object(
    'generated_at',now(),'household_id',v_household_id,'local_date',v_date,
    'urgent_actions',v_requests,'exceptions',v_waiting||v_carryover,
    'waiting_checks',v_waiting,'carryover',v_carryover,'handovers',v_handovers,
    'already_handled',v_handled,'tasks',v_tasks,'schedule',v_schedule,
    'shopping',v_shopping,'partner_summary',coalesce(v_partner,'{}'::jsonb),
    'sections',jsonb_build_object(
      'confirm_first',v_requests,'unusual',v_waiting||v_carryover,
      'handover',v_handovers,'already_handled',v_handled,
      'today_tasks',v_tasks,'shopping',v_shopping,'schedule',v_schedule
    )
  );
end; $$;

create or replace function public.get_my_request_workspace() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
return public.server_read_request_workspace(auth.uid()); end; $$;
create or replace function public.get_my_shopping_workspace() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
return public.server_read_shopping_workspace(auth.uid()); end; $$;
create or replace function public.get_my_task_result_history(p_since_local_date date default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
return public.server_read_task_result_history(auth.uid(),p_since_local_date); end; $$;
revoke all on function public.get_my_request_workspace() from public,anon;
revoke all on function public.get_my_shopping_workspace() from public,anon;
revoke all on function public.get_my_task_result_history(date) from public,anon;
grant execute on function public.get_my_request_workspace() to authenticated;
grant execute on function public.get_my_shopping_workspace() to authenticated;
grant execute on function public.get_my_task_result_history(date) to authenticated;

create or replace function private.fn_render_daily_brief_text_v1(p_brief jsonb)
returns text language plpgsql immutable security invoker set search_path='' as $$
declare v_text text:='今日のおうちノート'; v_part text;
begin
  select string_agg('・'||x->>'title',E'\n') into v_part
  from jsonb_array_elements(coalesce(p_brief->'urgent_actions','[]'::jsonb)) x;
  if v_part is not null then v_text:=v_text||E'\n\nまず確認\n'||v_part; end if;
  select string_agg('・'||x->>'title',E'\n') into v_part
  from jsonb_array_elements(coalesce(p_brief->'tasks','[]'::jsonb)) x;
  if v_part is not null then v_text:=v_text||E'\n\n今日やること\n'||v_part; end if;
  select string_agg('・'||x->>'title',E'\n') into v_part
  from jsonb_array_elements(coalesce(p_brief->'shopping','[]'::jsonb)) x;
  if v_part is not null then v_text:=v_text||E'\n\n買い物\n'||v_part; end if;
  return left(v_text,5000);
end; $$;
revoke all on function private.fn_render_daily_brief_text_v1(jsonb) from public,anon,authenticated;
grant execute on function private.fn_render_daily_brief_text_v1(jsonb) to service_role;

create or replace function public.server_tx_dispatch_daily_briefs(p_now timestamptz default now())
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_enabled boolean; r record; v_brief jsonb; v_receipt uuid; v_actor_ref uuid;
  v_dispatched int:=0; v_dedup text;
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
    v_receipt:=null;
    insert into private.scheduled_dispatch_receipts(
      household_id,schedule_kind,scheduled_local_date,recipient_user_id,dispatch_slot_key
    ) values (r.household_id,r.schedule_kind,r.local_date,r.recipient_user_id,r.dispatch_slot_key)
    on conflict do nothing returning id into v_receipt;
    if v_receipt is null then continue; end if;
    v_brief:=public.server_read_daily_brief(r.recipient_user_id,r.local_date);
    select id into v_actor_ref from public.domain_actor_refs where household_id=r.household_id
      and actor_kind='real_user' and real_user_id=r.recipient_user_id;
    v_dedup:='daily-brief:'||r.dispatch_slot_key;
    insert into public.user_notifications(
      household_id,recipient_user_id,type,title,body,payload,dedup_key,
      recipient_actor_ref_id,notification_kind,urgency,safety_class,bundle_key,
      business_expires_at,aggregate_type,aggregate_revision,test_context_id
    ) values (
      r.household_id,r.recipient_user_id,'daily_brief.v2',
      case when r.schedule_kind='evening_brief' then '夜のおうちノート' else '朝のおうちノート' end,
      private.fn_render_daily_brief_text_v1(v_brief),
      jsonb_build_object('brief',v_brief,'schedule_kind',r.schedule_kind),v_dedup,
      v_actor_ref,'daily_brief.v2','immediate','normal','daily-brief:'||r.recipient_user_id::text,
      r.scheduled_at+interval '8 hours','daily_brief',1,null
    ) on conflict(recipient_user_id,dedup_key) do nothing;
    v_dispatched:=v_dispatched+1;
  end loop;
  return jsonb_build_object('enabled',true,'dispatched',v_dispatched);
end; $$;
revoke all on function public.server_tx_dispatch_daily_briefs(timestamptz) from public,anon,authenticated;
grant execute on function public.server_tx_dispatch_daily_briefs(timestamptz) to service_role;

create or replace function public.server_tx_dispatch_family_ops_automation_v2(
  p_now_utc timestamptz default now(),p_row_limit int default 2000
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_daily jsonb; v_legacy jsonb; v_p1 boolean;
begin
  v_daily:=public.server_tx_dispatch_daily_briefs(p_now_utc);
  select release_stage='P1' into v_p1 from private.canonical_capability_gates
    where capability='daily_brief_v2';
  if coalesce(v_p1,false) then
    v_legacy:=jsonb_build_object('suppressed',true,'reason','DAILY_BRIEF_P1');
  else
    v_legacy:=public.server_tx_dispatch_routine_automation(p_now_utc,p_row_limit);
  end if;
  return jsonb_build_object('daily_brief',v_daily,'legacy',v_legacy);
end; $$;
revoke all on function public.server_tx_dispatch_family_ops_automation_v2(timestamptz,int) from public,anon,authenticated;
grant execute on function public.server_tx_dispatch_family_ops_automation_v2(timestamptz,int) to service_role;

-- Issue #48 five-HIGH hardening after first remediation CI.
-- Q50 waits for BOTH household responses; Q59 prunes unchanged undo scope;
-- Q64 preserves explicit unknown with carryover; Q110 covers external-follow
-- schedule changes and event-cancellation prep impact without auto-shifting.

-- ---------------------------------------------------------------------------
-- Q50: do not resolve on the first "review" response. Both users answer.
-- ---------------------------------------------------------------------------
create or replace function public.server_read_transport_conflict_reviews(p_actor_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_context jsonb; v_household_id uuid; v_result jsonb;
begin
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',g.id,'revision',g.revision,'status',g.status,'my_response',r.response,
    'responses',(select count(*) from public.transport_conflict_review_responses rr where rr.group_id=g.id),
    'required_responses',(select count(*) from public.household_members hm where hm.household_id=g.household_id),
    'items',(select coalesce(jsonb_agg(jsonb_build_object('task_id',i.task_instance_id,'date',i.occurrence_date,'leg',i.leg) order by i.occurrence_date,i.leg),'[]'::jsonb)
      from public.transport_conflict_review_items i where i.group_id=g.id)
  ) order by g.created_at desc),'[]'::jsonb) into v_result
  from public.transport_conflict_review_groups g
  left join public.transport_conflict_review_responses r on r.group_id=g.id and r.user_id=p_actor_id
  where g.household_id=v_household_id and g.status in ('pending','needs_review');
  return v_result;
end; $$;

create or replace function public.server_tx_respond_transport_conflict_review(
  p_actor_id uuid,p_operation_id uuid,p_group_id uuid,p_expected_revision bigint,p_response text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_context jsonb; v_household_id uuid; v_group public.transport_conflict_review_groups%rowtype;
  v_total int; v_answered int; v_keep int; v_review int; v_result jsonb;
  v_hash text; v_receipt private.mutation_receipts%rowtype; v_member record;
begin
  if p_response not in ('keep','review') then raise exception 'INVALID_INPUT'; end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  v_hash:=encode(sha256(convert_to('transport-conflict|'||p_group_id::text||'|'||p_expected_revision::text||'|'||p_response,'UTF8')),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
      values(p_actor_id,p_operation_id,'transport-conflict-review',v_hash)
      on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
    return v_receipt.result_payload;
  end loop;
  select * into v_group from public.transport_conflict_review_groups
    where id=p_group_id and household_id=v_household_id for update;
  if not found then raise exception 'TRANSPORT_REVIEW_NOT_FOUND'; end if;
  if v_group.status<>'pending' then raise exception 'TRANSPORT_REVIEW_NOT_PENDING'; end if;
  if v_group.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;

  insert into public.transport_conflict_review_responses(group_id,household_id,user_id,response)
    values(p_group_id,v_household_id,p_actor_id,p_response)
    on conflict(group_id,user_id) do update set response=excluded.response,updated_at=now();

  select count(*) into v_total from public.household_members where household_id=v_household_id;
  select count(*),count(*) filter(where response='keep'),count(*) filter(where response='review')
    into v_answered,v_keep,v_review from public.transport_conflict_review_responses where group_id=p_group_id;

  if v_answered>=v_total then
    if v_keep=v_total then
      update public.transport_conflict_review_groups set status='kept',resolved_at=now(),revision=revision+1 where id=p_group_id;
    else
      update public.transport_conflict_review_groups set status='needs_review',resolved_at=now(),revision=revision+1 where id=p_group_id;
      for v_member in select user_id from public.household_members where household_id=v_household_id loop
        insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
          values(v_household_id,v_member.user_id,'transport_conflict_adjusting','送り迎えの担当を見直します','元の個別合意は維持したまま、担当調整中にしました。',jsonb_build_object('review_group_id',p_group_id),'transport-conflict-adjusting:'||p_group_id::text)
          on conflict(recipient_user_id,dedup_key) do nothing;
      end loop;
    end if;
  else
    update public.transport_conflict_review_groups set revision=revision+1 where id=p_group_id;
  end if;
  select * into v_group from public.transport_conflict_review_groups where id=p_group_id;
  v_result:=jsonb_build_object(
    'id',v_group.id,'status',v_group.status,'revision',v_group.revision,
    'responses',v_answered,'required_responses',v_total,
    'q51_state',case when v_group.status='needs_review' then '担当調整中' else null end
  );
  update private.mutation_receipts set result_type='transport_conflict_review',result_id=p_group_id,result_payload=v_result
    where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end; $$;

-- ---------------------------------------------------------------------------
-- Q59: keep undo scope to rows actually changed by the bulk operation.
-- ---------------------------------------------------------------------------
create or replace function private.fn_prune_unchanged_routine_reconciliation_snapshot()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.before_state=new.after_state and cardinality(new.added_participant_ids)=0 then
    delete from public.routine_reconciliation_snapshots
      where operation_id=new.operation_id and task_instance_id=new.task_instance_id;
    return null;
  end if;
  return new;
end; $$;
drop trigger if exists prune_unchanged_routine_reconciliation_snapshot on public.routine_reconciliation_snapshots;
create trigger prune_unchanged_routine_reconciliation_snapshot
  after update of after_state,added_participant_ids on public.routine_reconciliation_snapshots
  for each row execute function private.fn_prune_unchanged_routine_reconciliation_snapshot();

-- ---------------------------------------------------------------------------
-- Q64: individual answer evidence is independent of operational carryover.
-- ---------------------------------------------------------------------------
create table public.routine_item_reconciliation_outcomes(
  household_id uuid not null references public.households(id),
  session_id uuid not null,
  task_instance_id uuid not null,
  actor_user_id uuid not null,
  outcome text not null check(outcome in ('completed','partner_handled','could_not_do','not_needed','cancelled','rescheduled','unknown')),
  rescheduled_to date null,
  source text not null check(source in ('pwa','line')),
  operation_id uuid not null,
  answered_at timestamptz not null default now(),
  primary key(session_id,task_instance_id),
  unique(actor_user_id,operation_id),
  foreign key(household_id,session_id) references public.routine_checkin_sessions(household_id,id),
  foreign key(household_id,task_instance_id) references public.task_instances(household_id,id),
  foreign key(household_id,actor_user_id) references public.household_members(household_id,user_id),
  check((outcome='rescheduled' and rescheduled_to is not null) or (outcome<>'rescheduled' and rescheduled_to is null))
);
revoke all on table public.routine_item_reconciliation_outcomes from public,anon,authenticated;
grant select,insert,update on table public.routine_item_reconciliation_outcomes to service_role;

create or replace function public.server_tx_routine_session_item_action_v3(
  p_actor_id uuid,p_operation_id uuid,p_session_id uuid,p_task_instance_id uuid,p_action text,p_source text,
  p_rescheduled_to date default null,p_reconciliation_operation_id uuid default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_context jsonb; v_household_id uuid; v_actor_ref uuid; v_session public.routine_checkin_sessions%rowtype;
  v_task public.task_instances%rowtype; v_result jsonb; v_outcome text; v_unanswered int; v_hash text;
  v_receipt private.mutation_receipts%rowtype; v_correction boolean:=false; v_before_status text;
begin
  if p_action not in ('complete','partner_handled','skip','failed','cancelled','rescheduled','unknown') or p_source not in ('pwa','line') then raise exception 'INVALID_INPUT'; end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid; v_actor_ref:=(v_context->>'actor_ref_id')::uuid;

  if p_action<>'unknown' then
    v_result:=public.server_tx_routine_session_item_action_v2(p_actor_id,p_operation_id,p_session_id,p_task_instance_id,p_action,p_source,p_rescheduled_to,p_reconciliation_operation_id);
  else
    v_hash:=encode(sha256(convert_to('routine-item-v3-unknown|'||p_session_id::text||'|'||p_task_instance_id::text||'|'||p_source||'|'||coalesce(p_reconciliation_operation_id::text,''),'UTF8')),'hex');
    loop
      insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
        values(p_actor_id,p_operation_id,'routine-session-item-unknown-v3',v_hash) on conflict(actor_id,operation_id) do nothing;
      if found then exit; end if;
      select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
      if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
      return v_receipt.result_payload;
    end loop;
    select * into v_session from public.routine_checkin_sessions where household_id=v_household_id and id=p_session_id for update;
    if not found or v_session.assignee_id<>p_actor_id then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
    if not exists(select 1 from public.routine_checkin_session_items where household_id=v_household_id and session_id=p_session_id and task_instance_id=p_task_instance_id) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
    if p_reconciliation_operation_id is not null then
      select (s.before_state->>'status'),true into v_before_status,v_correction
      from public.routine_reconciliation_operations o join public.routine_reconciliation_snapshots s on s.operation_id=o.id
      where o.id=p_reconciliation_operation_id and o.household_id=v_household_id and o.actor_user_id=p_actor_id and o.session_id=p_session_id and o.status='applied' and s.task_instance_id=p_task_instance_id;
    end if;
    if v_session.status<>'open' and not v_correction then raise exception 'TASK_TERMINAL'; end if;
    select * into v_task from public.task_instances where household_id=v_household_id and id=p_task_instance_id for update;
    if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
    if v_correction then
      update public.task_actual_participants set removed_at=now(),removed_by_actor_ref_id=v_actor_ref
        where household_id=v_household_id and task_instance_id=p_task_instance_id and removed_at is null;
    end if;
    update public.task_instances set
      status=case when coalesce(carryover_policy,'occurrence_ends')='occurrence_ends' then 'skipped'
                  else case when v_correction then coalesce(v_before_status,'todo') else status end end,
      actual_completed_by_id=null,completed_at=null,outcome_reason='unknown',rescheduled_to=null,
      revision=revision+1
      where household_id=v_household_id and id=p_task_instance_id;
    insert into public.task_events(household_id,task_instance_id,actor_id,event_type,payload,source,idempotency_key)
      values(v_household_id,p_task_instance_id,p_actor_id,'reconciled_unknown',jsonb_build_object('carryover_policy',v_task.carryover_policy),p_source,p_operation_id::text||':unknown');
    v_result:=jsonb_build_object('ok',true,'task_id',p_task_instance_id,'action','unknown');
    update private.mutation_receipts set result_type='task_instance',result_id=p_task_instance_id,result_payload=v_result
      where actor_id=p_actor_id and operation_id=p_operation_id;
  end if;

  v_outcome:=case p_action when 'complete' then 'completed' when 'partner_handled' then 'partner_handled'
    when 'failed' then 'could_not_do' when 'skip' then 'not_needed' when 'cancelled' then 'cancelled'
    when 'rescheduled' then 'rescheduled' else 'unknown' end;
  insert into public.routine_item_reconciliation_outcomes(household_id,session_id,task_instance_id,actor_user_id,outcome,rescheduled_to,source,operation_id)
    values(v_household_id,p_session_id,p_task_instance_id,p_actor_id,v_outcome,case when p_action='rescheduled' then p_rescheduled_to else null end,p_source,p_operation_id)
    on conflict(session_id,task_instance_id) do update set outcome=excluded.outcome,rescheduled_to=excluded.rescheduled_to,source=excluded.source,operation_id=excluded.operation_id,answered_at=now();

  if not v_correction then
    select count(*) into v_unanswered
    from public.routine_checkin_session_items si join public.task_instances ti on ti.household_id=si.household_id and ti.id=si.task_instance_id
    where si.household_id=v_household_id and si.session_id=p_session_id
      and ti.status in ('todo','in_progress')
      and not exists(select 1 from public.routine_item_reconciliation_outcomes o where o.session_id=p_session_id and o.task_instance_id=si.task_instance_id);
    if v_unanswered=0 then update public.routine_checkin_sessions set status='submitted',submitted_at=coalesce(submitted_at,now()) where household_id=v_household_id and id=p_session_id and status='open'; end if;
  end if;
  return coalesce(v_result,'{}'::jsonb)||jsonb_build_object('reconciliation_outcome',v_outcome);
end; $$;

-- ---------------------------------------------------------------------------
-- Q110: external-follow Google schedule changes also create prep candidates.
-- Q111 baseline: cancelling an event creates reviewable "prep unnecessary" candidates.
-- ---------------------------------------------------------------------------
alter table public.event_preparation_change_candidates alter column source_google_review_id drop not null;
alter table public.event_preparation_change_candidates add column if not exists source_kind text not null default 'protected_review';
alter table public.event_preparation_change_candidates add column if not exists source_external_etag text null;
alter table public.event_preparation_change_candidates add column if not exists proposal_kind text not null default 'reschedule';
alter table public.event_preparation_change_candidates drop constraint if exists event_preparation_change_candidates_source_kind_check;
alter table public.event_preparation_change_candidates add constraint event_preparation_change_candidates_source_kind_check check(source_kind in ('protected_review','external_follow','event_cancel'));
alter table public.event_preparation_change_candidates drop constraint if exists event_preparation_change_candidates_proposal_kind_check;
alter table public.event_preparation_change_candidates add constraint event_preparation_change_candidates_proposal_kind_check check(proposal_kind in ('reschedule','unnecessary'));
create unique index if not exists event_prep_external_follow_version_idx
  on public.event_preparation_change_candidates(family_event_id,task_instance_id,source_external_etag)
  where source_kind='external_follow';
create unique index if not exists event_prep_cancel_pending_idx
  on public.event_preparation_change_candidates(family_event_id,task_instance_id)
  where source_kind='event_cancel' and status='pending';

create or replace function private.fn_google_external_follow_prep_candidate_trigger_v1()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_link public.family_event_external_links%rowtype; v_cache public.calendar_events_cache%rowtype; v_auth text; v_day_delta int:=0; v_time_delta interval:=interval '0';
begin
  if row(old.all_day,old.starts_at,old.ends_at,old.starts_on,old.ends_on) is not distinct from row(new.all_day,new.starts_at,new.ends_at,new.starts_on,new.ends_on) then return new; end if;
  select * into v_link from public.family_event_external_links l where l.household_id=new.household_id and l.family_event_id=new.id and l.provider='google' and l.test_context_id is null order by l.created_at desc limit 1;
  if not found then return new; end if;
  select authority_mode into v_auth from public.family_event_field_authorities where household_id=new.household_id and family_event_id=new.id and field_name='schedule';
  if v_auth is distinct from 'external_follow' then return new; end if;
  select * into v_cache from public.calendar_events_cache c where c.calendar_connection_id=v_link.calendar_connection_id and c.google_event_id=v_link.google_event_id;
  if not found or v_cache.etag is not distinct from v_link.last_external_etag then return new; end if;
  if old.all_day and old.starts_on is not null and new.starts_on is not null then v_day_delta:=new.starts_on-old.starts_on;
  elsif not old.all_day and old.starts_at is not null and new.starts_at is not null then v_day_delta:=(new.starts_at at time zone 'Asia/Tokyo')::date-(old.starts_at at time zone 'Asia/Tokyo')::date; v_time_delta:=new.starts_at-old.starts_at; end if;
  insert into public.event_preparation_change_candidates(household_id,family_event_id,source_google_review_id,task_instance_id,task_revision,old_scheduled_date,proposed_scheduled_date,old_due_at,proposed_due_at,source_kind,source_external_etag,proposal_kind)
    select ti.household_id,new.id,null,ti.id,ti.revision,ti.scheduled_date,ti.scheduled_date+v_day_delta,ti.due_at,
      case when ti.due_at is null then null when v_time_delta<>interval '0' then ti.due_at+v_time_delta else ti.due_at+make_interval(days=>v_day_delta) end,
      'external_follow',v_cache.etag,'reschedule'
    from public.task_instances ti where ti.household_id=new.household_id and ti.event_id=new.id and ti.status in ('todo','in_progress') and ti.attention_state='active'
    on conflict do nothing;
  return new;
end; $$;
drop trigger if exists google_external_follow_prep_candidate_v1 on public.family_events;
create trigger google_external_follow_prep_candidate_v1
  after update of all_day,starts_at,ends_at,starts_on,ends_on on public.family_events
  for each row execute function private.fn_google_external_follow_prep_candidate_trigger_v1();

create or replace function private.fn_event_cancel_prep_candidate_trigger_v1()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.status is distinct from 'cancelled' and new.status='cancelled' then
    insert into public.event_preparation_change_candidates(household_id,family_event_id,source_google_review_id,task_instance_id,task_revision,old_scheduled_date,proposed_scheduled_date,old_due_at,proposed_due_at,source_kind,proposal_kind)
      select ti.household_id,new.id,null,ti.id,ti.revision,ti.scheduled_date,ti.scheduled_date,ti.due_at,ti.due_at,'event_cancel','unnecessary'
      from public.task_instances ti where ti.household_id=new.household_id and ti.event_id=new.id and ti.status in ('todo','in_progress')
      on conflict do nothing;
  end if;
  return new;
end; $$;
drop trigger if exists event_cancel_prep_candidate_v1 on public.family_events;
create trigger event_cancel_prep_candidate_v1 after update of status on public.family_events
  for each row execute function private.fn_event_cancel_prep_candidate_trigger_v1();

create or replace function public.server_read_google_event_reviews_v2(p_actor_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_base jsonb; v_context jsonb; v_household_id uuid; v_prep jsonb;
begin
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id); v_household_id:=(v_context->>'household_id')::uuid;
  v_base:=public.server_read_google_event_reviews(p_actor_id);
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,'revision',c.revision,'candidate_kind','preparation_change','proposal_kind',c.proposal_kind,
    'source_kind',c.source_kind,'family_event_id',c.family_event_id,'family_event_title',e.title,
    'task_instance_id',c.task_instance_id,'task_title',t.title,'old_scheduled_date',c.old_scheduled_date,
    'proposed_scheduled_date',c.proposed_scheduled_date,'old_due_at',c.old_due_at,'proposed_due_at',c.proposed_due_at,
    'task_revision',c.task_revision) order by c.created_at desc),'[]'::jsonb) into v_prep
  from public.event_preparation_change_candidates c
  join public.family_events e on e.household_id=c.household_id and e.id=c.family_event_id
  join public.task_instances t on t.household_id=c.household_id and t.id=c.task_instance_id
  where c.household_id=v_household_id and c.status='pending';
  return coalesce(v_base,'[]'::jsonb)||v_prep;
end; $$;

create or replace function public.server_tx_resolve_event_preparation_change(p_actor_id uuid,p_operation_id uuid,p_candidate_id uuid,p_expected_revision bigint,p_resolution text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_context jsonb; v_household_id uuid; v_actor_ref uuid; v_c public.event_preparation_change_candidates%rowtype; v_t public.task_instances%rowtype; v_hash text; v_receipt private.mutation_receipts%rowtype; v_result jsonb;
begin
  if p_resolution not in ('apply','keep') then raise exception 'INVALID_INPUT'; end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id); v_household_id:=(v_context->>'household_id')::uuid; v_actor_ref:=(v_context->>'actor_ref_id')::uuid;
  v_hash:=encode(sha256(convert_to('prep-change|'||p_candidate_id::text||'|'||p_expected_revision::text||'|'||p_resolution,'UTF8')),'hex');
  loop insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash) values(p_actor_id,p_operation_id,'event-preparation-change',v_hash) on conflict(actor_id,operation_id) do nothing; if found then exit; end if; select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update; if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if; return v_receipt.result_payload; end loop;
  select * into v_c from public.event_preparation_change_candidates where id=p_candidate_id and household_id=v_household_id for update;
  if not found then raise exception 'PREPARATION_REVIEW_NOT_FOUND'; end if; if v_c.status<>'pending' or v_c.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  select * into v_t from public.task_instances where household_id=v_household_id and id=v_c.task_instance_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if p_resolution='apply' then
    if v_t.revision<>v_c.task_revision or v_t.status not in ('todo','in_progress') then raise exception 'PREPARATION_REVIEW_STALE'; end if;
    if v_c.proposal_kind='unnecessary' then
      update public.task_instances set status='skipped',outcome_reason='not_needed_this_occurrence',rescheduled_to=null,revision=revision+1 where household_id=v_household_id and id=v_t.id;
    else
      update public.task_instances set scheduled_date=v_c.proposed_scheduled_date,due_at=v_c.proposed_due_at,revision=revision+1 where household_id=v_household_id and id=v_t.id;
    end if;
  end if;
  update public.event_preparation_change_candidates set status='resolved',resolution=p_resolution,resolved_at=now(),resolved_by_actor_ref_id=v_actor_ref,revision=revision+1 where id=v_c.id;
  v_result:=jsonb_build_object('candidate_id',v_c.id,'proposal_kind',v_c.proposal_kind,'resolution',p_resolution,'status','resolved');
  update private.mutation_receipts set result_type='event_preparation_change',result_id=v_c.id,result_payload=v_result where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end; $$;

revoke all on function public.server_tx_routine_session_item_action_v3(uuid,uuid,uuid,uuid,text,text,date,uuid) from public,anon,authenticated;
revoke all on function public.server_read_transport_conflict_reviews(uuid) from public,anon,authenticated;
revoke all on function public.server_tx_respond_transport_conflict_review(uuid,uuid,uuid,bigint,text) from public,anon,authenticated;
revoke all on function public.server_read_google_event_reviews_v2(uuid) from public,anon,authenticated;
revoke all on function public.server_tx_resolve_event_preparation_change(uuid,uuid,uuid,bigint,text) from public,anon,authenticated;
revoke all on function private.fn_prune_unchanged_routine_reconciliation_snapshot() from public,anon,authenticated;
revoke all on function private.fn_google_external_follow_prep_candidate_trigger_v1() from public,anon,authenticated;
revoke all on function private.fn_event_cancel_prep_candidate_trigger_v1() from public,anon,authenticated;
grant execute on function public.server_tx_routine_session_item_action_v3(uuid,uuid,uuid,uuid,text,text,date,uuid) to service_role;
grant execute on function public.server_read_transport_conflict_reviews(uuid) to service_role;
grant execute on function public.server_tx_respond_transport_conflict_review(uuid,uuid,uuid,bigint,text) to service_role;
grant execute on function public.server_read_google_event_reviews_v2(uuid) to service_role;
grant execute on function public.server_tx_resolve_event_preparation_change(uuid,uuid,uuid,bigint,text) to service_role;
grant execute on function private.fn_prune_unchanged_routine_reconciliation_snapshot() to service_role;
grant execute on function private.fn_google_external_follow_prep_candidate_trigger_v1() to service_role;
grant execute on function private.fn_event_cancel_prep_candidate_trigger_v1() to service_role;

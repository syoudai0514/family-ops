-- Issue #48 independent re-review remediation: Q50 / Q59 / Q64 / Q110 / Q111.
-- Additive closeout only: do not weaken canonical provider/idempotency boundaries.

-- ---------------------------------------------------------------------------
-- Q64: preserve exact individual reconciliation truth.
-- ---------------------------------------------------------------------------
alter table public.task_instances
  add column if not exists rescheduled_to date null;

alter table public.task_instances
  drop constraint if exists task_instances_outcome_reason_check;
alter table public.task_instances
  add constraint task_instances_outcome_reason_check
  check (outcome_reason is null or outcome_reason in (
    'could_not_do','not_needed_this_occurrence','expired_occurrence','rescheduled','unknown'
  ));

alter table public.task_instances
  drop constraint if exists task_instances_rescheduled_to_check;
alter table public.task_instances
  add constraint task_instances_rescheduled_to_check
  check ((outcome_reason='rescheduled' and rescheduled_to is not null) or (outcome_reason<>'rescheduled' or outcome_reason is null) and rescheduled_to is null);

-- ---------------------------------------------------------------------------
-- Q59: durable bulk reconciliation receipt + exact-scope CAS undo.
-- ---------------------------------------------------------------------------
create table public.routine_reconciliation_operations (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  actor_user_id uuid not null,
  session_id uuid not null,
  response_kind text not null check (response_kind in ('all_done','mostly_done','individual')),
  status text not null default 'applied' check (status in ('applied','undone')),
  before_session_status text not null,
  after_session_status text not null,
  created_at timestamptz not null default now(),
  undone_at timestamptz null,
  unique(household_id,id),
  unique(actor_user_id,id),
  foreign key(household_id,actor_user_id) references public.household_members(household_id,user_id),
  foreign key(household_id,session_id) references public.routine_checkin_sessions(household_id,id)
);

create table public.routine_reconciliation_snapshots (
  operation_id uuid not null references public.routine_reconciliation_operations(id) on delete cascade,
  household_id uuid not null references public.households(id),
  task_instance_id uuid not null,
  before_state jsonb not null,
  after_state jsonb not null,
  added_participant_ids uuid[] not null default '{}'::uuid[],
  primary key(operation_id,task_instance_id),
  foreign key(household_id,task_instance_id) references public.task_instances(household_id,id)
);

revoke all on table public.routine_reconciliation_operations from public,anon,authenticated;
revoke all on table public.routine_reconciliation_snapshots from public,anon,authenticated;
grant select,insert,update on table public.routine_reconciliation_operations to service_role;
grant select,insert,update on table public.routine_reconciliation_snapshots to service_role;

create or replace function public.server_tx_reconcile_routine_session_v2(
  p_actor_id uuid,
  p_operation_id uuid,
  p_session_id uuid,
  p_response_kind text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_session public.routine_checkin_sessions%rowtype;
  v_sub_op uuid;
  v_result jsonb;
  v_existing public.routine_reconciliation_operations%rowtype;
  v_before_participants jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_session_id is null
     or p_response_kind not in ('all_done','mostly_done','individual') then
    raise exception 'INVALID_INPUT';
  end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;

  select * into v_existing from public.routine_reconciliation_operations
    where actor_user_id=p_actor_id and id=p_operation_id;
  if found then
    if v_existing.session_id<>p_session_id or v_existing.response_kind<>p_response_kind then
      raise exception 'IDEMPOTENCY_CONFLICT';
    end if;
    return jsonb_build_object('ok',true,'reconciliation_operation_id',v_existing.id,'status',v_existing.status);
  end if;

  select * into v_session from public.routine_checkin_sessions
    where household_id=v_household_id and id=p_session_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_session.assignee_id<>p_actor_id or v_session.status<>'open' then
    raise exception 'ROUTINE_SESSION_NOT_ACTIONABLE';
  end if;

  insert into public.routine_reconciliation_operations(
    id,household_id,actor_user_id,session_id,response_kind,before_session_status,after_session_status
  ) values(p_operation_id,v_household_id,p_actor_id,p_session_id,p_response_kind,v_session.status,v_session.status);

  insert into public.routine_reconciliation_snapshots(operation_id,household_id,task_instance_id,before_state,after_state)
  select p_operation_id,v_household_id,ti.id,
    jsonb_build_object(
      'status',ti.status,'actual_completed_by_id',ti.actual_completed_by_id,'completed_at',ti.completed_at,
      'outcome_reason',ti.outcome_reason,'rescheduled_to',ti.rescheduled_to,'attention_state',ti.attention_state,
      'waiting_note',ti.waiting_note,'next_check_at',ti.next_check_at,'revision',ti.revision
    ), '{}'::jsonb
  from public.routine_checkin_session_items si
  join public.task_instances ti on ti.household_id=si.household_id and ti.id=si.task_instance_id
  where si.household_id=v_household_id and si.session_id=p_session_id
    and ti.status in ('todo','in_progress') and ti.attention_state='active';

  select coalesce(jsonb_object_agg(x.task_instance_id::text,x.participants),'{}'::jsonb) into v_before_participants
  from (
    select s.task_instance_id,coalesce(jsonb_agg(p.id) filter(where p.id is not null),'[]'::jsonb) participants
    from public.routine_reconciliation_snapshots s
    left join public.task_actual_participants p on p.household_id=s.household_id
      and p.task_instance_id=s.task_instance_id and p.removed_at is null
    where s.operation_id=p_operation_id
    group by s.task_instance_id
  ) x;

  v_sub_op:=(md5(p_operation_id::text||':canonical-reconcile'))::uuid;
  v_result:=public.server_tx_reconcile_routine_session(p_actor_id,v_sub_op,p_session_id,p_response_kind);

  update public.routine_reconciliation_snapshots s set
    after_state=jsonb_build_object(
      'status',ti.status,'actual_completed_by_id',ti.actual_completed_by_id,'completed_at',ti.completed_at,
      'outcome_reason',ti.outcome_reason,'rescheduled_to',ti.rescheduled_to,'attention_state',ti.attention_state,
      'waiting_note',ti.waiting_note,'next_check_at',ti.next_check_at,'revision',ti.revision
    ),
    added_participant_ids=coalesce((
      select array_agg(p.id order by p.id)
      from public.task_actual_participants p
      where p.household_id=s.household_id and p.task_instance_id=s.task_instance_id and p.removed_at is null
        and not (p.id::text = any(select jsonb_array_elements_text(coalesce(v_before_participants->s.task_instance_id::text,'[]'::jsonb))))
    ),'{}'::uuid[])
  from public.task_instances ti
  where s.operation_id=p_operation_id and ti.household_id=s.household_id and ti.id=s.task_instance_id;

  select * into v_session from public.routine_checkin_sessions where household_id=v_household_id and id=p_session_id;
  update public.routine_reconciliation_operations set after_session_status=v_session.status where id=p_operation_id;

  return coalesce(v_result,'{}'::jsonb)||jsonb_build_object('reconciliation_operation_id',p_operation_id,'undo_available',p_response_kind='all_done');
end;
$$;

create or replace function public.server_tx_undo_routine_reconciliation(
  p_actor_id uuid,
  p_operation_id uuid,
  p_target_operation_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_target public.routine_reconciliation_operations%rowtype;
  v_snap public.routine_reconciliation_snapshots%rowtype;
  v_task public.task_instances%rowtype;
  v_actor_ref uuid;
  v_hash text;
  v_receipt private.mutation_receipts%rowtype;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_target_operation_id is null then raise exception 'INVALID_INPUT'; end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  v_actor_ref:=(v_context->>'actor_ref_id')::uuid;
  v_hash:=encode(sha256(convert_to('routine-undo|'||p_target_operation_id::text,'UTF8')),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
      values(p_actor_id,p_operation_id,'routine-reconciliation-undo',v_hash)
      on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
    return v_receipt.result_payload;
  end loop;

  select * into v_target from public.routine_reconciliation_operations
    where id=p_target_operation_id and household_id=v_household_id and actor_user_id=p_actor_id for update;
  if not found then raise exception 'RECONCILIATION_OPERATION_NOT_FOUND'; end if;
  if v_target.status<>'applied' then raise exception 'RECONCILIATION_ALREADY_UNDONE'; end if;
  if v_target.response_kind<>'all_done' then raise exception 'RECONCILIATION_UNDO_NOT_AVAILABLE'; end if;

  for v_snap in select * from public.routine_reconciliation_snapshots where operation_id=v_target.id order by task_instance_id loop
    select * into v_task from public.task_instances where household_id=v_household_id and id=v_snap.task_instance_id for update;
    if v_task.revision<>coalesce((v_snap.after_state->>'revision')::bigint,-1)
       or v_task.status<>coalesce(v_snap.after_state->>'status','') then
      raise exception 'RECONCILIATION_UNDO_STALE';
    end if;
  end loop;

  for v_snap in select * from public.routine_reconciliation_snapshots where operation_id=v_target.id order by task_instance_id loop
    update public.task_actual_participants set removed_at=now(),removed_by_actor_ref_id=v_actor_ref
      where household_id=v_household_id and id=any(v_snap.added_participant_ids) and removed_at is null;
    update public.task_instances set
      status=v_snap.before_state->>'status',
      actual_completed_by_id=nullif(v_snap.before_state->>'actual_completed_by_id','')::uuid,
      completed_at=nullif(v_snap.before_state->>'completed_at','')::timestamptz,
      outcome_reason=nullif(v_snap.before_state->>'outcome_reason',''),
      rescheduled_to=nullif(v_snap.before_state->>'rescheduled_to','')::date,
      attention_state=coalesce(v_snap.before_state->>'attention_state','active'),
      waiting_note=nullif(v_snap.before_state->>'waiting_note',''),
      next_check_at=nullif(v_snap.before_state->>'next_check_at','')::timestamptz,
      revision=revision+1
    where household_id=v_household_id and id=v_snap.task_instance_id;
  end loop;

  if v_target.before_session_status='open' and v_target.after_session_status='submitted' then
    update public.routine_checkin_sessions set status='open',submitted_at=null
      where household_id=v_household_id and id=v_target.session_id and status='submitted';
  end if;
  update public.routine_reconciliation_operations set status='undone',undone_at=now() where id=v_target.id;
  v_result:=jsonb_build_object('ok',true,'target_operation_id',v_target.id,'status','undone');
  update private.mutation_receipts set result_type='routine_reconciliation',result_id=v_target.id,result_payload=v_result
    where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;

create or replace function public.server_tx_routine_session_item_action_v2(
  p_actor_id uuid,
  p_operation_id uuid,
  p_session_id uuid,
  p_task_instance_id uuid,
  p_action text,
  p_source text,
  p_rescheduled_to date default null,
  p_reconciliation_operation_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_context jsonb; v_household_id uuid; v_session public.routine_checkin_sessions%rowtype;
  v_task public.task_instances%rowtype; v_sub_op uuid; v_remaining int; v_result jsonb;
  v_hash text; v_receipt private.mutation_receipts%rowtype; v_correction_ok boolean:=false;
begin
  if p_actor_id is null or p_operation_id is null or p_session_id is null or p_task_instance_id is null
     or p_action not in ('complete','partner_handled','skip','failed','cancelled','rescheduled','unknown')
     or p_source not in ('pwa','line') then raise exception 'INVALID_INPUT'; end if;
  if p_action='rescheduled' and p_rescheduled_to is null then raise exception 'RESCHEDULE_DATE_REQUIRED'; end if;
  if p_action<>'rescheduled' and p_rescheduled_to is not null then raise exception 'INVALID_INPUT'; end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id); v_household_id:=(v_context->>'household_id')::uuid;
  v_hash:=encode(sha256(convert_to('routine-item-v2|'||p_session_id::text||'|'||p_task_instance_id::text||'|'||p_action||'|'||coalesce(p_rescheduled_to::text,'')||'|'||p_source||'|'||coalesce(p_reconciliation_operation_id::text,''),'UTF8')),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
      values(p_actor_id,p_operation_id,'routine-session-item-action-v2',v_hash) on conflict(actor_id,operation_id) do nothing;
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
    v_correction_ok:=exists(select 1 from public.routine_reconciliation_operations o join public.routine_reconciliation_snapshots s on s.operation_id=o.id
      where o.id=p_reconciliation_operation_id and o.household_id=v_household_id and o.actor_user_id=p_actor_id and o.session_id=p_session_id and o.status='applied' and s.task_instance_id=p_task_instance_id);
  end if;
  if v_session.status<>'open' and not v_correction_ok then raise exception 'TASK_TERMINAL'; end if;
  select * into v_task from public.task_instances where household_id=v_household_id and id=p_task_instance_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_task.status not in ('todo','in_progress') and not v_correction_ok then
    v_result:=jsonb_build_object('ok',true,'task_id',p_task_instance_id,'status',v_task.status,'already_terminal',true);
  elsif p_action in ('complete','partner_handled') then
    if v_task.status in ('todo','in_progress') then
      v_sub_op:=(md5(p_operation_id::text||':complete'))::uuid;
      perform public.server_tx_complete_task(p_actor_id,v_sub_op,p_task_instance_id,case when p_action='complete' then 'self' else 'partner' end,true,p_source);
    end if;
    v_result:=jsonb_build_object('ok',true,'task_id',p_task_instance_id,'action',p_action);
  else
    update public.task_actual_participants set removed_at=now(),removed_by_actor_ref_id=(v_context->>'actor_ref_id')::uuid
      where household_id=v_household_id and task_instance_id=p_task_instance_id and removed_at is null;
    update public.task_instances set
      status=case when p_action='cancelled' then 'cancelled' else 'skipped' end,
      actual_completed_by_id=null,completed_at=null,attention_state='active',waiting_note=null,next_check_at=null,
      outcome_reason=case p_action when 'failed' then 'could_not_do' when 'skip' then 'not_needed_this_occurrence' when 'rescheduled' then 'rescheduled' when 'unknown' then 'unknown' else null end,
      rescheduled_to=case when p_action='rescheduled' then p_rescheduled_to else null end,
      revision=revision+1
    where household_id=v_household_id and id=p_task_instance_id;
    insert into public.task_events(household_id,task_instance_id,actor_id,event_type,source,idempotency_key)
      values(v_household_id,p_task_instance_id,p_actor_id,case when p_action='cancelled' then 'cancelled' else 'skipped' end,p_source,p_operation_id::text||':'||p_action);
    v_result:=jsonb_build_object('ok',true,'task_id',p_task_instance_id,'action',p_action,'rescheduled_to',p_rescheduled_to);
  end if;
  select count(*) into v_remaining from public.routine_checkin_session_items si join public.task_instances ti on ti.household_id=si.household_id and ti.id=si.task_instance_id
    where si.household_id=v_household_id and si.session_id=p_session_id and ti.status in ('todo','in_progress');
  if v_remaining=0 then update public.routine_checkin_sessions set status='submitted',submitted_at=coalesce(submitted_at,now()) where id=p_session_id and status='open'; end if;
  v_result:=v_result||jsonb_build_object('session_remaining',v_remaining);
  update private.mutation_receipts set result_type='task_instance',result_id=p_task_instance_id,result_payload=v_result where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;

-- Enrich the existing read without changing its authorization model.
create or replace function public.server_tx_get_routine_session(p_actor_id uuid,p_session_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_household_id uuid; v_session record; v_items jsonb; v_current uuid;
begin
  if p_actor_id is null or p_session_id is null then raise exception 'INVALID_INPUT'; end if;
  select household_id into v_household_id from public.household_members where user_id=p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select * into v_session from public.routine_checkin_sessions where household_id=v_household_id and id=p_session_id;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'task_instance_id',ti.id,'title',ti.title,'status',ti.status,'completion_mode',ti.completion_mode,
    'actual_completed_by_id',ti.actual_completed_by_id,'outcome_reason',ti.outcome_reason,'rescheduled_to',ti.rescheduled_to,
    'revision',ti.revision,'display_order',si.display_order,'subtasks',(
      select coalesce(jsonb_agg(jsonb_build_object('id',st.id,'title',st.title,'required',st.required,'is_completed',st.is_completed,'completed_by',st.completed_by) order by st.sort_order),'[]'::jsonb)
      from public.task_subtask_instances st where st.household_id=v_household_id and st.task_instance_id=ti.id
    )) order by si.display_order),'[]'::jsonb) into v_items
  from public.routine_checkin_session_items si join public.task_instances ti on ti.household_id=si.household_id and ti.id=si.task_instance_id
  where si.household_id=v_household_id and si.session_id=p_session_id;
  if v_session.status='superseded' then select id into v_current from public.routine_checkin_sessions where household_id=v_household_id and session_type=v_session.session_type and scheduled_date=v_session.scheduled_date and status<>'superseded' order by opened_at desc limit 1; end if;
  return jsonb_build_object('id',v_session.id,'session_type',v_session.session_type,'scheduled_date',v_session.scheduled_date,'assignee_id',v_session.assignee_id,'status',v_session.status,'assignment_generation',v_session.assignment_generation,'opened_at',v_session.opened_at,'submitted_at',v_session.submitted_at,'can_act',v_session.status='open' and v_session.assignee_id=p_actor_id,'current_session_id',v_current,'items',v_items);
end; $$;

-- ---------------------------------------------------------------------------
-- Q50: explicit grouped confirmation by both household adults/users.
-- ---------------------------------------------------------------------------
create table public.transport_conflict_review_groups(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  template_id uuid not null,
  created_by uuid not null,
  status text not null default 'pending' check(status in ('pending','kept','needs_review')),
  revision bigint not null default 1,
  created_at timestamptz not null default now(),
  resolved_at timestamptz null,
  unique(household_id,id),
  unique(template_id),
  foreign key(household_id,template_id) references public.transport_weekly_templates(household_id,id),
  foreign key(household_id,created_by) references public.household_members(household_id,user_id)
);
create table public.transport_conflict_review_items(
  group_id uuid not null references public.transport_conflict_review_groups(id) on delete cascade,
  household_id uuid not null references public.households(id),
  task_instance_id uuid not null,
  occurrence_date date not null,
  leg text not null check(leg in ('dropoff','pickup')),
  primary key(group_id,task_instance_id),
  foreign key(household_id,task_instance_id) references public.task_instances(household_id,id)
);
create table public.transport_conflict_review_responses(
  group_id uuid not null references public.transport_conflict_review_groups(id) on delete cascade,
  household_id uuid not null references public.households(id),
  user_id uuid not null,
  response text not null check(response in ('keep','review')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(group_id,user_id),
  foreign key(household_id,user_id) references public.household_members(household_id,user_id)
);
revoke all on table public.transport_conflict_review_groups,public.transport_conflict_review_items,public.transport_conflict_review_responses from public,anon,authenticated;
grant select,insert,update on table public.transport_conflict_review_groups,public.transport_conflict_review_items,public.transport_conflict_review_responses to service_role;

create or replace function public.server_tx_save_transport_template_v2(p_actor_id uuid,p_operation_id uuid,p_valid_from date,p_days jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_context jsonb; v_household_id uuid; v_result jsonb; v_group uuid; v_template uuid; v_conf jsonb; v_count int:=0; v_member record;
begin
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id); v_household_id:=(v_context->>'household_id')::uuid;
  v_result:=public.server_tx_save_transport_template(p_actor_id,p_operation_id,p_valid_from,p_days);
  v_template:=(v_result->>'template_id')::uuid;
  v_count:=jsonb_array_length(coalesce(v_result->'protected_conflicts','[]'::jsonb));
  if v_count>0 then
    insert into public.transport_conflict_review_groups(household_id,template_id,created_by)
      values(v_household_id,v_template,p_actor_id) on conflict(template_id) do update set template_id=excluded.template_id returning id into v_group;
    for v_conf in select value from jsonb_array_elements(v_result->'protected_conflicts') loop
      insert into public.transport_conflict_review_items(group_id,household_id,task_instance_id,occurrence_date,leg)
        values(v_group,v_household_id,(v_conf->>'task_id')::uuid,(v_conf->>'date')::date,v_conf->>'leg') on conflict do nothing;
    end loop;
    for v_member in select user_id from public.household_members where household_id=v_household_id loop
      insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
        values(v_household_id,v_member.user_id,'transport_conflict_review','個別の送り迎え予定を確認','生活パターン変更後も個別合意は維持しています。維持するか見直すか確認してください。',jsonb_build_object('review_group_id',v_group,'template_id',v_template),'transport-conflict-review:'||v_group::text)
        on conflict(recipient_user_id,dedup_key) do nothing;
    end loop;
    v_result:=v_result||jsonb_build_object('conflict_review_group_id',v_group,'confirmation_required',true);
  end if;
  return v_result;
end; $$;

create or replace function public.server_read_transport_conflict_reviews(p_actor_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_context jsonb; v_household_id uuid; v_result jsonb;
begin
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id); v_household_id:=(v_context->>'household_id')::uuid;
  select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'revision',g.revision,'status',g.status,'my_response',r.response,'items',(
    select coalesce(jsonb_agg(jsonb_build_object('task_id',i.task_instance_id,'date',i.occurrence_date,'leg',i.leg) order by i.occurrence_date,i.leg),'[]'::jsonb) from public.transport_conflict_review_items i where i.group_id=g.id
  )) order by g.created_at desc),'[]'::jsonb) into v_result
  from public.transport_conflict_review_groups g left join public.transport_conflict_review_responses r on r.group_id=g.id and r.user_id=p_actor_id
  where g.household_id=v_household_id and g.status='pending';
  return v_result;
end; $$;

create or replace function public.server_tx_respond_transport_conflict_review(p_actor_id uuid,p_operation_id uuid,p_group_id uuid,p_expected_revision bigint,p_response text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_context jsonb; v_household_id uuid; v_group public.transport_conflict_review_groups%rowtype; v_total int; v_keep int; v_review int; v_result jsonb; v_hash text; v_receipt private.mutation_receipts%rowtype;
begin
  if p_response not in ('keep','review') then raise exception 'INVALID_INPUT'; end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id); v_household_id:=(v_context->>'household_id')::uuid;
  v_hash:=encode(sha256(convert_to('transport-conflict|'||p_group_id::text||'|'||p_expected_revision::text||'|'||p_response,'UTF8')),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash) values(p_actor_id,p_operation_id,'transport-conflict-review',v_hash) on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if; select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if; return v_receipt.result_payload;
  end loop;
  select * into v_group from public.transport_conflict_review_groups where id=p_group_id and household_id=v_household_id for update;
  if not found then raise exception 'TRANSPORT_REVIEW_NOT_FOUND'; end if; if v_group.status<>'pending' then raise exception 'TRANSPORT_REVIEW_NOT_PENDING'; end if; if v_group.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  insert into public.transport_conflict_review_responses(group_id,household_id,user_id,response) values(p_group_id,v_household_id,p_actor_id,p_response)
    on conflict(group_id,user_id) do update set response=excluded.response,updated_at=now();
  select count(*) into v_total from public.household_members where household_id=v_household_id;
  select count(*) filter(where response='keep'),count(*) filter(where response='review') into v_keep,v_review from public.transport_conflict_review_responses where group_id=p_group_id;
  if v_review>0 then update public.transport_conflict_review_groups set status='needs_review',resolved_at=now(),revision=revision+1 where id=p_group_id;
  elsif v_keep=v_total then update public.transport_conflict_review_groups set status='kept',resolved_at=now(),revision=revision+1 where id=p_group_id;
  else update public.transport_conflict_review_groups set revision=revision+1 where id=p_group_id; end if;
  select * into v_group from public.transport_conflict_review_groups where id=p_group_id;
  v_result:=jsonb_build_object('id',v_group.id,'status',v_group.status,'revision',v_group.revision,'q51_state',case when v_group.status='needs_review' then '担当調整中' else null end);
  update private.mutation_receipts set result_type='transport_conflict_review',result_id=p_group_id,result_payload=v_result where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end; $$;

-- ---------------------------------------------------------------------------
-- Q110/Q111: linked preparation review + literal Google deletion 3-way choice.
-- ---------------------------------------------------------------------------
alter table public.family_events add column if not exists schedule_review_state text not null default 'scheduled';
alter table public.family_events drop constraint if exists family_events_schedule_review_state_check;
alter table public.family_events add constraint family_events_schedule_review_state_check check(schedule_review_state in ('scheduled','waiting_reschedule'));

alter table public.google_event_review_candidates drop constraint if exists google_event_review_candidates_resolution_check;
alter table public.google_event_review_candidates add constraint google_event_review_candidates_resolution_check
  check(resolution is null or resolution in ('accept_google','keep_family','same_event','different_event','cancel_family','waiting_reschedule','google_only_hidden'));

create table public.event_preparation_change_candidates(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  family_event_id uuid not null,
  source_google_review_id uuid not null references public.google_event_review_candidates(id),
  task_instance_id uuid not null,
  task_revision bigint not null,
  old_scheduled_date date not null,
  proposed_scheduled_date date not null,
  old_due_at timestamptz null,
  proposed_due_at timestamptz null,
  status text not null default 'pending' check(status in ('pending','resolved','superseded')),
  resolution text null check(resolution is null or resolution in ('apply','keep')),
  revision bigint not null default 1,
  created_at timestamptz not null default now(),
  resolved_at timestamptz null,
  resolved_by_actor_ref_id uuid null,
  unique(source_google_review_id,task_instance_id),
  unique(household_id,id),
  foreign key(household_id,family_event_id) references public.family_events(household_id,id),
  foreign key(household_id,task_instance_id) references public.task_instances(household_id,id),
  foreign key(household_id,resolved_by_actor_ref_id) references public.domain_actor_refs(household_id,id)
);
revoke all on table public.event_preparation_change_candidates from public,anon,authenticated;
grant select,insert,update on table public.event_preparation_change_candidates to service_role;

create or replace function public.server_tx_resolve_google_event_review(
  p_actor_id uuid,p_operation_id uuid,p_candidate_id uuid,p_expected_revision bigint,p_resolution text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_context jsonb; v_household_id uuid; v_actor_ref_id uuid; v_candidate public.google_event_review_candidates%rowtype;
  v_hash text; v_receipt private.mutation_receipts%rowtype; v_result jsonb; v_link_id uuid; v_old_event public.family_events%rowtype;
  v_day_delta int:=0;
begin
  if p_actor_id is null or p_operation_id is null or p_candidate_id is null or p_expected_revision is null
     or p_resolution not in ('accept_google','keep_family','same_event','different_event','cancel_family','waiting_reschedule','google_only_hidden') then raise exception 'INVALID_INPUT'; end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id); v_household_id:=(v_context->>'household_id')::uuid; v_actor_ref_id:=(v_context->>'actor_ref_id')::uuid;
  v_hash:=encode(sha256(convert_to('google-event-review|'||p_candidate_id::text||'|'||p_expected_revision::text||'|'||p_resolution,'UTF8')),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash) values(p_actor_id,p_operation_id,'google-event-review',v_hash) on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if; select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if; return v_receipt.result_payload;
  end loop;
  select * into v_candidate from public.google_event_review_candidates where id=p_candidate_id and household_id=v_household_id for update;
  if not found then raise exception 'GOOGLE_REVIEW_NOT_FOUND'; end if; if v_candidate.status<>'pending' then raise exception 'GOOGLE_REVIEW_NOT_PENDING'; end if; if v_candidate.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  select * into v_old_event from public.family_events where household_id=v_household_id and id=v_candidate.family_event_id for update;

  if v_candidate.candidate_kind='possible_duplicate' then
    if p_resolution not in ('same_event','different_event') then raise exception 'GOOGLE_REVIEW_RESOLUTION_INVALID'; end if;
    if p_resolution='same_event' then
      insert into public.family_event_external_links(household_id,family_event_id,provider,calendar_connection_id,google_event_id,link_mode,last_external_etag,last_reconciled_at,writer_enabled,ownership_transfer_state)
      values(v_household_id,v_candidate.family_event_id,'google',v_candidate.calendar_connection_id,v_candidate.google_event_id,'external_follow',v_candidate.source_etag,now(),false,'inactive') on conflict(calendar_connection_id,google_event_id) do nothing returning id into v_link_id;
      if v_link_id is null and not exists(select 1 from public.family_event_external_links where calendar_connection_id=v_candidate.calendar_connection_id and google_event_id=v_candidate.google_event_id and family_event_id=v_candidate.family_event_id) then raise exception 'GOOGLE_EVENT_ALREADY_LINKED'; end if;
      update public.google_event_review_candidates set status='superseded',revision=revision+1 where calendar_connection_id=v_candidate.calendar_connection_id and google_event_id=v_candidate.google_event_id and candidate_kind='possible_duplicate' and status='pending' and id<>v_candidate.id;
    end if;
  elsif v_candidate.candidate_kind='protected_change' then
    if p_resolution not in ('accept_google','keep_family') then raise exception 'GOOGLE_REVIEW_RESOLUTION_INVALID'; end if;
    if p_resolution='accept_google' then
      if 'schedule'=any(v_candidate.changed_fields) then
        if v_candidate.google_all_day and v_old_event.starts_on is not null and v_candidate.google_starts_on is not null then v_day_delta:=v_candidate.google_starts_on-v_old_event.starts_on;
        elsif not v_candidate.google_all_day and v_old_event.starts_at is not null and v_candidate.google_starts_at is not null then v_day_delta:=(v_candidate.google_starts_at at time zone 'Asia/Tokyo')::date-(v_old_event.starts_at at time zone 'Asia/Tokyo')::date; end if;
      end if;
      update public.family_events e set
        title=case when 'title'=any(v_candidate.changed_fields) then coalesce(nullif(btrim(v_candidate.google_title),''),e.title) else e.title end,
        all_day=case when 'schedule'=any(v_candidate.changed_fields) then v_candidate.google_all_day else e.all_day end,
        starts_on=case when 'schedule'=any(v_candidate.changed_fields) then case when v_candidate.google_all_day then v_candidate.google_starts_on else null end else e.starts_on end,
        ends_on=case when 'schedule'=any(v_candidate.changed_fields) then case when v_candidate.google_all_day then v_candidate.google_ends_on else null end else e.ends_on end,
        starts_at=case when 'schedule'=any(v_candidate.changed_fields) then case when v_candidate.google_all_day then null else v_candidate.google_starts_at end else e.starts_at end,
        ends_at=case when 'schedule'=any(v_candidate.changed_fields) then case when v_candidate.google_all_day then null else v_candidate.google_ends_at end else e.ends_at end,
        location_text=case when 'location'=any(v_candidate.changed_fields) then v_candidate.google_location_text else e.location_text end,
        schedule_review_state='scheduled',revision=e.revision+1 where e.household_id=v_household_id and e.id=v_candidate.family_event_id;
      if 'schedule'=any(v_candidate.changed_fields) then
        insert into public.event_preparation_change_candidates(household_id,family_event_id,source_google_review_id,task_instance_id,task_revision,old_scheduled_date,proposed_scheduled_date,old_due_at,proposed_due_at)
        select ti.household_id,ti.event_id,v_candidate.id,ti.id,ti.revision,ti.scheduled_date,ti.scheduled_date+v_day_delta,ti.due_at,
          case when ti.due_at is null then null else ti.due_at+make_interval(days=>v_day_delta) end
        from public.task_instances ti where ti.household_id=v_household_id and ti.event_id=v_candidate.family_event_id
          and ti.status in ('todo','in_progress') and ti.attention_state='active'
        on conflict(source_google_review_id,task_instance_id) do nothing;
      end if;
    end if;
  elsif v_candidate.candidate_kind='google_deleted' then
    if p_resolution not in ('accept_google','keep_family','cancel_family','waiting_reschedule','google_only_hidden') then raise exception 'GOOGLE_REVIEW_RESOLUTION_INVALID'; end if;
    if p_resolution in ('accept_google','cancel_family') then
      update public.family_events set status='cancelled',schedule_review_state='scheduled',revision=revision+1 where household_id=v_household_id and id=v_candidate.family_event_id;
    elsif p_resolution='waiting_reschedule' then
      update public.family_events set schedule_review_state='waiting_reschedule',revision=revision+1 where household_id=v_household_id and id=v_candidate.family_event_id;
    elsif p_resolution='google_only_hidden' then
      delete from public.family_event_external_links where household_id=v_household_id and family_event_id=v_candidate.family_event_id and calendar_connection_id=v_candidate.calendar_connection_id and google_event_id=v_candidate.google_event_id;
      update public.family_events set schedule_review_state='scheduled',revision=revision+1 where household_id=v_household_id and id=v_candidate.family_event_id;
    end if;
  end if;
  update public.google_event_review_candidates set status='resolved',resolution=p_resolution,resolved_at=now(),resolved_by_actor_ref_id=v_actor_ref_id,revision=revision+1 where id=v_candidate.id;
  if v_candidate.candidate_kind='possible_duplicate' and p_resolution='same_event' then perform private.fn_reconcile_google_cache_row_to_family_event_v1(v_candidate.calendar_connection_id,v_candidate.google_event_id); end if;
  v_result:=jsonb_build_object('candidate_id',v_candidate.id,'candidate_kind',v_candidate.candidate_kind,'resolution',p_resolution,'status','resolved');
  update private.mutation_receipts set result_type='google_event_review',result_id=v_candidate.id,result_payload=v_result where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end; $$;

create or replace function public.server_read_google_event_reviews_v2(p_actor_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_base jsonb; v_context jsonb; v_household_id uuid; v_prep jsonb;
begin
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id); v_household_id:=(v_context->>'household_id')::uuid;
  v_base:=public.server_read_google_event_reviews(p_actor_id);
  select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'revision',c.revision,'candidate_kind','preparation_change','family_event_id',c.family_event_id,'family_event_title',e.title,'task_instance_id',c.task_instance_id,'task_title',t.title,'old_scheduled_date',c.old_scheduled_date,'proposed_scheduled_date',c.proposed_scheduled_date,'old_due_at',c.old_due_at,'proposed_due_at',c.proposed_due_at,'task_revision',c.task_revision) order by c.created_at desc),'[]'::jsonb) into v_prep
  from public.event_preparation_change_candidates c join public.family_events e on e.household_id=c.household_id and e.id=c.family_event_id join public.task_instances t on t.household_id=c.household_id and t.id=c.task_instance_id
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
    update public.task_instances set scheduled_date=v_c.proposed_scheduled_date,due_at=v_c.proposed_due_at,revision=revision+1 where household_id=v_household_id and id=v_t.id;
  end if;
  update public.event_preparation_change_candidates set status='resolved',resolution=p_resolution,resolved_at=now(),resolved_by_actor_ref_id=v_actor_ref,revision=revision+1 where id=v_c.id;
  v_result:=jsonb_build_object('candidate_id',v_c.id,'resolution',p_resolution,'status','resolved'); update private.mutation_receipts set result_type='event_preparation_change',result_id=v_c.id,result_payload=v_result where actor_id=p_actor_id and operation_id=p_operation_id; return v_result;
end; $$;

-- Locked-down server entry points.
revoke all on function public.server_tx_reconcile_routine_session_v2(uuid,uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.server_tx_undo_routine_reconciliation(uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.server_tx_routine_session_item_action_v2(uuid,uuid,uuid,uuid,text,text,date,uuid) from public,anon,authenticated;
revoke all on function public.server_tx_get_routine_session(uuid,uuid) from public,anon,authenticated;
revoke all on function public.server_tx_save_transport_template_v2(uuid,uuid,date,jsonb) from public,anon,authenticated;
revoke all on function public.server_read_transport_conflict_reviews(uuid) from public,anon,authenticated;
revoke all on function public.server_tx_respond_transport_conflict_review(uuid,uuid,uuid,bigint,text) from public,anon,authenticated;
revoke all on function public.server_tx_resolve_google_event_review(uuid,uuid,uuid,bigint,text) from public,anon,authenticated;
revoke all on function public.server_read_google_event_reviews_v2(uuid) from public,anon,authenticated;
revoke all on function public.server_tx_resolve_event_preparation_change(uuid,uuid,uuid,bigint,text) from public,anon,authenticated;
grant execute on function public.server_tx_reconcile_routine_session_v2(uuid,uuid,uuid,text) to service_role;
grant execute on function public.server_tx_undo_routine_reconciliation(uuid,uuid,uuid) to service_role;
grant execute on function public.server_tx_routine_session_item_action_v2(uuid,uuid,uuid,uuid,text,text,date,uuid) to service_role;
grant execute on function public.server_tx_get_routine_session(uuid,uuid) to service_role;
grant execute on function public.server_tx_save_transport_template_v2(uuid,uuid,date,jsonb) to service_role;
grant execute on function public.server_read_transport_conflict_reviews(uuid) to service_role;
grant execute on function public.server_tx_respond_transport_conflict_review(uuid,uuid,uuid,bigint,text) to service_role;
grant execute on function public.server_tx_resolve_google_event_review(uuid,uuid,uuid,bigint,text) to service_role;
grant execute on function public.server_read_google_event_reviews_v2(uuid) to service_role;
grant execute on function public.server_tx_resolve_event_preparation_change(uuid,uuid,uuid,bigint,text) to service_role;

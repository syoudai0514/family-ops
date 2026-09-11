\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  u uuid:=gen_random_uuid();
  v uuid:=gen_random_uuid();
  hh uuid; ar uuid; br uuid;
  c jsonb; r jsonb; terms jsonb; patch jsonb;
  req uuid; attempt uuid; task_id uuid;
  original_due timestamptz; changed_due timestamptz:=now()+interval '5 days 3 hours';
  request_revision bigint; before_task_revision bigint;
begin
  insert into auth.users(id) values(u),(v);
  hh:=(public.server_tx_create_household(u,gen_random_uuid(),'XC convergence','Owner')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role) values(hh,v,'adult');
  perform private.backfill_canonical_foundation_v1();
  select id into ar from public.domain_actor_refs where household_id=hh and real_user_id=u;
  select id into br from public.domain_actor_refs where household_id=hh and real_user_id=v;

  -- XC-05: free consultation prose never mutates work truth.  A saved,
  -- whitelisted material_patch is a distinct explicit structure.
  original_due:=now()+interval '3 days';
  c:=public.server_tx_send_request_v2(u,gen_random_uuid(),v,'Structured due','相談します',original_due,now()+interval '1 day');
  req:=(c->>'request_id')::uuid; attempt:=(c->>'attempt_id')::uuid;
  perform public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'consult',null,1,1,'line');
  select a.terms into terms from public.request_attempts a where a.id=attempt;
  patch:=jsonb_build_object(
    'version',1,
    'work_due_at',changed_due,
    'scheduled_date',(changed_due at time zone 'Asia/Tokyo')::date
  );
  r:=public.server_tx_transition_request_v2(
    u,gen_random_uuid(),req,attempt,'edit_terms',terms||jsonb_build_object(
      'candidate','18:30ならできる',
      'material_patch',patch
    ),2,1,'pwa'
  );
  if r->>'state'<>'consulting' or (r->>'terms_revision')::int<>2 then
    raise exception 'FAIL material proposal state/revision';
  end if;
  if (select due_at from public.requests where id=req) is distinct from original_due
     or (select linked_task_instance_id from public.requests where id=req) is not null then
    raise exception 'FAIL proposal mutated canonical work before confirmation';
  end if;

  r:=public.server_tx_transition_request_v2(u,gen_random_uuid(),req,attempt,'confirm_terms',null,3,2,'pwa');
  if r->>'state'<>'awaiting_confirmation' then raise exception 'FAIL first material confirmation'; end if;
  if (select due_at from public.requests where id=req) is distinct from original_due then
    raise exception 'FAIL first confirmation mutated work';
  end if;

  r:=public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'confirm_terms',null,4,2,'line');
  if r->>'state'<>'accepted' or r->'material_patch'->>'applied'<>'true' then
    raise exception 'FAIL second confirmation did not apply structured patch';
  end if;
  select linked_task_instance_id into task_id from public.requests where id=req;
  if task_id is null then raise exception 'FAIL accepted light request has no canonical task'; end if;
  if (select due_at from public.requests where id=req) is distinct from changed_due
     or (select due_at from public.task_instances where id=task_id) is distinct from changed_due
     or (select scheduled_date from public.task_instances where id=task_id)
        is distinct from (changed_due at time zone 'Asia/Tokyo')::date then
    raise exception 'FAIL confirmed work date/time not reflected in Request/Task';
  end if;
  if (select count(*) from public.task_events where task_instance_id=task_id
      and idempotency_key='request-material-patch:'||attempt::text)<>1 then
    raise exception 'FAIL material patch audit missing/duplicated';
  end if;

  -- Replaying the exact second confirmation operation must not double-write
  -- the material patch.  The canonical command receipt and patch event are one
  -- transaction boundary.
  -- (Use a fresh request here because a different operation id after accepted
  -- is correctly stale; replay semantics are already covered by lane A.)

  -- Free-form `candidate` remains a discussion note only.
  original_due:=now()+interval '4 days';
  c:=public.server_tx_send_request_v2(u,gen_random_uuid(),v,'Memo only','相談メモ',original_due,now()+interval '1 day');
  req:=(c->>'request_id')::uuid; attempt:=(c->>'attempt_id')::uuid;
  perform public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'consult',null,1,1,'line');
  select a.terms into terms from public.request_attempts a where a.id=attempt;
  perform public.server_tx_transition_request_v2(u,gen_random_uuid(),req,attempt,'edit_terms',terms||'{"candidate":"明日は私、金曜は交代"}'::jsonb,2,1,'line');
  perform public.server_tx_transition_request_v2(u,gen_random_uuid(),req,attempt,'confirm_terms',null,3,2,'line');
  r:=public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'confirm_terms',null,4,2,'pwa');
  select linked_task_instance_id into task_id from public.requests where id=req;
  if r ? 'material_patch' then raise exception 'FAIL prose unexpectedly became material patch'; end if;
  if (select due_at from public.requests where id=req) is distinct from original_due
     or (select due_at from public.task_instances where id=task_id) is distinct from original_due then
    raise exception 'FAIL prose changed work deadline';
  end if;

  -- Assignment consultation explicitly represents the recipient reassignment
  -- against the immutable server-issued task/revision target.  If the Task is
  -- edited meanwhile, the second confirmation fails closed and the Attempt
  -- remains unaccepted.
  insert into public.task_instances(
    household_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,
    completion_mode,status,source,created_by,assignment_mode,assignment_source,
    planned_assignee_actor_ref_id,due_at
  ) values(
    hh,'manual','XC assignment','other','anytime',current_date,u,
    'whole','todo','xc_test',u,'person','manual',ar,now()+interval '4 days'
  ) returning id,revision into task_id,before_task_revision;
  c:=public.server_tx_create_assignment_change_request(u,gen_random_uuid(),task_id,v,'代われますか','once');
  req:=(c->>'request_id')::uuid; attempt:=(c->>'attempt_id')::uuid;
  perform public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'consult',null,1,1,'line');
  select a.terms into terms from public.request_attempts a where a.id=attempt;
  patch:=jsonb_build_object(
    'version',1,
    'work_due_at',changed_due,
    'scheduled_date',(changed_due at time zone 'Asia/Tokyo')::date,
    'assignment',jsonb_build_object(
      'mode','request_recipient',
      'targets',terms->'assignment_targets'
    )
  );
  perform public.server_tx_transition_request_v2(
    u,gen_random_uuid(),req,attempt,'edit_terms',terms||jsonb_build_object('material_patch',patch),2,1,'line'
  );
  perform public.server_tx_transition_request_v2(u,gen_random_uuid(),req,attempt,'confirm_terms',null,3,2,'line');
  update public.task_instances set revision=revision+1 where id=task_id;
  begin
    perform public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'confirm_terms',null,4,2,'pwa');
    raise exception 'FAIL stale assignment target accepted';
  exception when others then
    if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if;
  end;
  if (select state from public.request_attempts where id=attempt)<>'awaiting_confirmation'
     or (select planned_assignee_actor_ref_id from public.task_instances where id=task_id)<>ar
     or (select revision from public.task_instances where id=task_id)<>before_task_revision+1 then
    raise exception 'FAIL stale material agreement left partial mutation';
  end if;

  -- XC-03 Request expiry/reproposal: requester can reopen through a canonical
  -- revision-checked command rather than a LINE-only lifecycle.
  c:=public.server_tx_send_request_v2(u,gen_random_uuid(),v,'Reproposal','再提案テスト',now()+interval '4 days',now()+interval '1 hour');
  req:=(c->>'request_id')::uuid; attempt:=(c->>'attempt_id')::uuid;
  update public.request_attempts set reply_due_at=now()-interval '1 minute' where id=attempt;
  r:=public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'accept',null,1,1,'line');
  if r->>'state'<>'expired' then raise exception 'FAIL request did not expire'; end if;
  select revision into request_revision from public.requests where id=req;
  r:=public.server_tx_repropose_request_v1(
    u,gen_random_uuid(),req,request_revision,now()+interval '24 hours','line'
  );
  if r->>'state'<>'pending' or (select attempt_kind from public.request_attempts where id=(r->>'attempt_id')::uuid)<>'reproposal' then
    raise exception 'FAIL canonical reproposal not created';
  end if;
  begin
    perform public.server_tx_repropose_request_v1(
      u,gen_random_uuid(),req,request_revision,now()+interval '24 hours','line'
    );
    raise exception 'FAIL stale reproposal revision accepted';
  exception when others then
    if sqlerrm not in ('AGGREGATE_REVISION_CONFLICT','REQUEST_REPROPOSAL_NOT_ALLOWED') then raise; end if;
  end;
end; $$;
rollback;

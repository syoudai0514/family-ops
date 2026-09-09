-- CF-01 / CF-12. Additive Request command cutover; no production data reset.
-- RequestAttempt is the only negotiation owner. Scoped task revisions are
-- agreement terms, not a second lifecycle or a legacy scope-table dependency.

create or replace function private.fn_propose_request_reply_due_v1(p_work_due timestamptz, p_anchor timestamptz)
returns timestamptz language sql immutable set search_path = '' as $$
  select case when p_work_due > p_anchor
    then least(p_anchor + interval '24 hours', p_anchor + (p_work_due - p_anchor) / 2)
    else p_anchor + interval '24 hours' end
$$;
revoke all on function private.fn_propose_request_reply_due_v1(timestamptz,timestamptz) from public, anon, authenticated;
grant execute on function private.fn_propose_request_reply_due_v1(timestamptz,timestamptz) to service_role;

create or replace function private.fn_expire_request_attempt_v1(p_household_id uuid, p_request_id uuid, p_attempt_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare a public.request_attempts%rowtype;
begin
  -- Consistent request -> attempt -> task lock ordering, including workers.
  perform 1 from public.requests where household_id=p_household_id and id=p_request_id for update;
  select * into a from public.request_attempts where household_id=p_household_id
    and request_id=p_request_id and id=p_attempt_id for update;
  if a.state in ('pending','checking','consulting','awaiting_confirmation') and a.reply_due_at <= now() then
    update public.request_attempts set state='expired', expired_at=now(), revision=revision+1 where id=a.id;
    perform private.fn_project_request_legacy_lifecycle_v1(p_household_id,p_request_id);
    return true;
  end if;
  return a.state='expired';
end; $$;
revoke all on function private.fn_expire_request_attempt_v1(uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function private.fn_expire_request_attempt_v1(uuid,uuid,uuid) to service_role;

create or replace function public.server_tx_expire_request_attempts_v1()
returns integer language plpgsql security invoker set search_path = '' as $$
declare a record; n integer:=0;
begin
  for a in select household_id, request_id, id from public.request_attempts
    where state in ('pending','checking','consulting','awaiting_confirmation') and reply_due_at <= now()
    order by request_id,id limit 500
  loop
    if private.fn_expire_request_attempt_v1(a.household_id,a.request_id,a.id) then n:=n+1; end if;
  end loop;
  return n;
end; $$;
revoke all on function public.server_tx_expire_request_attempts_v1() from public, anon, authenticated;
grant execute on function public.server_tx_expire_request_attempts_v1() to service_role;

create or replace function private.fn_apply_request_assignment_v1(
 p_request_id uuid,p_attempt_id uuid,p_actor_ref_id uuid,p_operator_id uuid,p_source text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare r public.requests%rowtype; a public.request_attempts%rowtype;
 t public.task_instances%rowtype; target jsonb; targets jsonb; recipient_user uuid;
begin
 select * into r from public.requests where id=p_request_id for update;
 select * into a from public.request_attempts where id=p_attempt_id and request_id=r.id for update;
 if r.request_kind is distinct from 'assignment_change' or a.state is distinct from 'accepted' then
   raise exception 'REQUEST_TRANSITION_INVALID'; end if;
 targets:=a.terms->'assignment_targets';
 if targets is null or jsonb_typeof(targets)<>'array' or jsonb_array_length(targets)=0 then
   raise exception 'REQUEST_ASSIGNMENT_REPROPOSAL_REQUIRED'; end if;
 if (select count(*) from jsonb_array_elements(targets)) <>
    (select count(distinct e->>'task_id') from jsonb_array_elements(targets) e) then
   raise exception 'REQUEST_ASSIGNMENT_SCOPE_INVALID'; end if;
 recipient_user:=private.fn_legacy_user_for_actor_ref_v1(r.household_id,r.recipient_actor_ref_id,r.test_context_id);
 -- First validate/lock every task in UUID order. Any failure rolls back the
 -- accepted state, assignments, history, receipt and notification together.
 for target in select e from jsonb_array_elements(targets) e order by e->>'task_id' loop
   select * into t from public.task_instances where household_id=r.household_id
     and id=(target->>'task_id')::uuid for update;
   if not found or t.test_context_id is distinct from r.test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
   if t.revision is distinct from (target->>'revision')::bigint
      or t.planned_assignee_actor_ref_id is distinct from (target->>'assignee_actor_ref_id')::uuid then
     raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
   if t.status not in ('todo','in_progress') then raise exception 'TASK_NOT_OPEN'; end if;
 end loop;
 for target in select e from jsonb_array_elements(targets) e order by e->>'task_id' loop
   update public.task_instances set assignment_mode='person',assignment_source='agreement',
     planned_assignee_actor_ref_id=r.recipient_actor_ref_id,
     planned_assignee_id=case when r.test_context_id is null then recipient_user else null end,
     active_claimant_actor_ref_id=null,claimed_at=null,revision=revision+1
   where household_id=r.household_id and id=(target->>'task_id')::uuid returning * into t;
   insert into public.task_events(household_id,task_instance_id,actor_id,actor_ref_id,test_context_id,event_type,payload,source,idempotency_key)
   values(r.household_id,t.id,private.fn_legacy_user_for_actor_ref_v1(r.household_id,p_actor_ref_id,r.test_context_id),
     p_actor_ref_id,r.test_context_id,'assignment_agreed',
     jsonb_build_object('request_id',r.id,'attempt_id',a.id,'terms_revision',a.terms_revision,
       'previous_assignee_actor_ref_id',target->'assignee_actor_ref_id','previous_revision',target->'revision',
       'assignee_actor_ref_id',r.recipient_actor_ref_id,'revision',t.revision),p_source,
     'request-assignment:'||a.id::text||':'||t.id::text);
 end loop;
 update public.requests set linked_task_instance_id=assignment_task_instance_id where id=r.id;
 return r.assignment_task_instance_id;
end; $$;
revoke all on function private.fn_apply_request_assignment_v1(uuid,uuid,uuid,uuid,text) from public, anon, authenticated;
grant execute on function private.fn_apply_request_assignment_v1(uuid,uuid,uuid,uuid,text) to service_role;

create or replace function private.fn_command_transition_request_attempt_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_request_id uuid,
  p_attempt_id uuid,
  p_action text,
  p_terms jsonb,
  p_expected_revision bigint,
  p_expected_terms_revision int,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_request public.requests%rowtype;
  v_attempt public.request_attempts%rowtype;
  v_party text;
  v_new_state text;
  v_new_revision bigint;
  v_new_terms_revision int;
  v_confirmations int;
  v_task_id uuid;
  v_result jsonb;
begin
  if p_action not in ('checking', 'consult', 'edit_terms', 'confirm_terms', 'accept', 'decline', 'cancel') then
    raise exception 'REQUEST_ATTEMPT_ACTION_INVALID';
  end if;
  if p_source not in ('line', 'pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
    p_operation_id, 'request.attempt.' || p_action,
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'request_id', p_request_id, 'attempt_id', p_attempt_id, 'action', p_action,
      'terms', coalesce(p_terms, '{}'::jsonb), 'expected_revision', p_expected_revision,
      'expected_terms_revision', p_expected_terms_revision, 'source', p_source
    ))
  );
  if v_claim->>'disposition' = 'replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_request from public.requests
  where household_id = p_household_id and id = p_request_id for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  v_party := private.fn_request_party_role_v1(v_request, p_actor_ref_id);

  select * into v_attempt from public.request_attempts
  where household_id = p_household_id and id = p_attempt_id and request_id = p_request_id
  for update;
  if not found then raise exception 'REQUEST_ATTEMPT_NOT_FOUND'; end if;
  if v_attempt.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if private.fn_expire_request_attempt_v1(p_household_id,p_request_id,p_attempt_id) then
    v_result:=jsonb_build_object('request_id',p_request_id,'attempt_id',p_attempt_id,
      'state','expired','code','REQUEST_ATTEMPT_EXPIRED','reproposal_required',true);
    perform private.fn_complete_canonical_operation_v1(v_receipt_id,'request',p_request_id,v_result);
    return v_result;
  end if;
  if p_expected_terms_revision is distinct from v_attempt.terms_revision then
    raise exception 'REQUEST_TERMS_REVISION_STALE';
  end if;
  if v_attempt.revision is distinct from p_expected_revision then raise exception 'REQUEST_ATTEMPT_STALE'; end if;
  if v_attempt.state in ('accepted', 'declined', 'expired', 'cancelled') then raise exception 'REQUEST_ATTEMPT_STALE'; end if;

  v_new_state := v_attempt.state;
  v_new_terms_revision := v_attempt.terms_revision;

  if p_action = 'checking' then
    if v_party <> 'recipient' or v_attempt.state <> 'pending' then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    v_new_state := 'checking';
    update public.request_attempts set state = v_new_state, revision = revision + 1 where id = v_attempt.id returning revision into v_new_revision;

  elsif p_action = 'consult' then
    if v_attempt.state not in ('pending', 'checking') then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    v_new_state := 'consulting';
    update public.request_attempts set state = v_new_state, revision = revision + 1 where id = v_attempt.id returning revision into v_new_revision;

  elsif p_action = 'edit_terms' then
    if v_attempt.state not in ('consulting', 'awaiting_confirmation') then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    if p_terms is null or p_terms = '{}'::jsonb then raise exception 'REQUEST_TERMS_REQUIRED'; end if;
    if v_request.request_kind='assignment_change' then
      -- A text comment cannot redefine task/date/swap semantics. Concrete
      -- task scope/revisions must remain the server-issued agreement snapshot.
      if p_terms->'assignment_targets' is distinct from v_attempt.terms->'assignment_targets'
        or p_terms->'due_at' is distinct from v_attempt.terms->'due_at' then
        raise exception 'REQUEST_ASSIGNMENT_REPROPOSAL_REQUIRED';
      end if;
    end if;
    v_new_terms_revision := v_attempt.terms_revision + 1;
    v_new_state := 'awaiting_confirmation';
    update public.request_attempts
    set terms = p_terms,
        terms_revision = v_new_terms_revision,
        state = v_new_state,
        revision = revision + 1
    where id = v_attempt.id returning revision into v_new_revision;
    insert into public.request_attempt_confirmations (
      household_id, attempt_id, terms_revision, actor_ref_id, test_context_id
    ) values (
      p_household_id, v_attempt.id, v_new_terms_revision, p_actor_ref_id, p_test_context_id
    ) on conflict do nothing;

  elsif p_action = 'confirm_terms' then
    if v_attempt.state not in ('consulting', 'awaiting_confirmation') then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    if p_expected_terms_revision is null or p_expected_terms_revision <> v_attempt.terms_revision then
      raise exception 'REQUEST_TERMS_REVISION_STALE';
    end if;
    insert into public.request_attempt_confirmations (
      household_id, attempt_id, terms_revision, actor_ref_id, test_context_id
    ) values (
      p_household_id, v_attempt.id, v_attempt.terms_revision, p_actor_ref_id, p_test_context_id
    ) on conflict do nothing;

    select count(*) into v_confirmations
    from public.request_attempt_confirmations c
    where c.attempt_id = v_attempt.id
      and c.terms_revision = v_attempt.terms_revision
      and c.actor_ref_id in (v_request.requester_actor_ref_id, v_request.recipient_actor_ref_id);

    if v_confirmations >= 2 then
      v_new_state := 'accepted';
      update public.request_attempts
      set state = 'accepted', accepted_at = now(), revision = revision + 1
      where id = v_attempt.id returning revision into v_new_revision;
    else
      v_new_state := 'awaiting_confirmation';
      update public.request_attempts
      set state = 'awaiting_confirmation', revision = revision + 1
      where id = v_attempt.id returning revision into v_new_revision;
    end if;

  elsif p_action = 'accept' then
    if v_party <> 'recipient' or v_attempt.state not in ('pending', 'checking') then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    v_new_state := 'accepted';
    update public.request_attempts
    set state = 'accepted', accepted_at = now(), revision = revision + 1
    where id = v_attempt.id returning revision into v_new_revision;

  elsif p_action = 'decline' then
    if v_party <> 'recipient' or v_attempt.state not in ('pending', 'checking') then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    v_new_state := 'declined';
    update public.request_attempts
    set state = 'declined', declined_at = now(), revision = revision + 1
    where id = v_attempt.id returning revision into v_new_revision;

  else
    if v_party <> 'requester' then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    v_new_state := 'cancelled';
    update public.request_attempts
    set state = 'cancelled', cancelled_at = now(), revision = revision + 1
    where id = v_attempt.id returning revision into v_new_revision;
  end if;

  perform private.fn_project_request_legacy_lifecycle_v1(p_household_id, p_request_id);

  if v_new_state = 'accepted' and v_attempt.attempt_kind in ('initial', 'reproposal') then
    if v_request.request_kind = 'light' then
      v_task_id := private.fn_ensure_light_request_task_v1(p_request_id, p_operator_user_id);
    elsif v_request.request_kind = 'assignment_change' then
      v_task_id:=private.fn_apply_request_assignment_v1(p_request_id,p_attempt_id,p_actor_ref_id,p_operator_user_id,p_source);
    end if;
  end if;

  if p_action = 'checking' then
    perform private.fn_emit_notification_intent_v1(
      p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
      v_request.requester_actor_ref_id, 'request.checking', '確認中です',
      v_request.shared_title,
      jsonb_build_object('request_id', p_request_id, 'attempt_id', p_attempt_id, 'state', v_new_state),
      'request:checking:' || p_attempt_id::text || ':' || v_new_revision::text,
      'immediate', 'normal', 'request:' || p_request_id::text,
      v_request.due_at, 'request', p_request_id, v_new_revision
    );
  elsif v_new_state in ('accepted', 'declined', 'cancelled') then
    perform private.fn_emit_notification_intent_v1(
      p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
      case when v_party = 'recipient' then v_request.requester_actor_ref_id else v_request.recipient_actor_ref_id end,
      'request.' || v_new_state, 'お願いを更新しました', v_request.shared_title,
      jsonb_build_object('request_id', p_request_id, 'attempt_id', p_attempt_id, 'state', v_new_state, 'task_id', v_task_id),
      'request:' || v_new_state || ':' || p_attempt_id::text || ':' || v_new_revision::text,
      'immediate', 'normal', 'request:' || p_request_id::text,
      v_request.due_at, 'request', p_request_id, v_new_revision
    );
  end if;

  v_result := jsonb_build_object(
    'request_id', p_request_id, 'attempt_id', p_attempt_id,
    'state', v_new_state, 'revision', v_new_revision,
    'terms_revision', v_new_terms_revision, 'linked_task_id', v_task_id
  );
  perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'request', p_request_id, v_result);
  return v_result;
end;
$$;
revoke all on function private.fn_command_transition_request_attempt_v1(uuid, uuid, uuid, uuid, uuid, uuid, text, jsonb, bigint, int, uuid, text) from public, anon, authenticated;
grant execute on function private.fn_command_transition_request_attempt_v1(uuid, uuid, uuid, uuid, uuid, uuid, text, jsonb, bigint, int, uuid, text) to service_role;

create or replace function public.server_tx_create_assignment_change_request(
 p_actor_id uuid,p_operation_id uuid,p_task_id uuid,p_recipient_user_id uuid,p_shared_message text,p_scope text
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare c jsonb; hh uuid; actor_ref uuid; recipient_ref uuid; t public.task_instances%rowtype;
 candidate public.task_instances%rowtype; targets jsonb:='[]'; claim jsonb; result jsonb; request_id uuid; attempt_id uuid; reply_due timestamptz;
begin
 c:=private.fn_require_production_actor_context_v1(p_actor_id); hh:=(c->>'household_id')::uuid; actor_ref:=(c->>'actor_ref_id')::uuid;
 if p_scope is null or p_scope not in ('once','this_week') then raise exception 'INVALID_INPUT'; end if;
 select id into recipient_ref from public.domain_actor_refs where household_id=hh and actor_kind='real_user' and real_user_id=p_recipient_user_id;
 if recipient_ref is null or recipient_ref=actor_ref then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
 claim:=private.fn_claim_canonical_operation_v1(hh,p_actor_id,actor_ref,null,p_operation_id,'request.create.assignment_change',
   private.fn_canonical_request_hash_v1(jsonb_build_object('task_id',p_task_id,'recipient',recipient_ref,'message',p_shared_message,'scope',p_scope)));
 if claim->>'disposition'='replay' then return claim->'result_payload'; end if;
 select * into t from public.task_instances where household_id=hh and id=p_task_id and test_context_id is null;
 if not found then raise exception 'TASK_NOT_FOUND'; end if;
 if t.planned_assignee_actor_ref_id is distinct from actor_ref or t.status not in ('todo','in_progress') then
   raise exception 'ASSIGNMENT_CHANGE_NOT_ALLOWED'; end if;
 for candidate in select * from public.task_instances x where x.household_id=hh and x.test_context_id is null
   and x.status in ('todo','in_progress') and x.planned_assignee_actor_ref_id=actor_ref
   and (x.id=t.id or (p_scope='this_week' and t.task_definition_id is not null and x.task_definition_id=t.task_definition_id
     and x.scheduled_date between t.scheduled_date and (t.scheduled_date+(7-extract(isodow from t.scheduled_date)::integer))))
   order by x.id for update
 loop
   targets:=targets||jsonb_build_array(jsonb_build_object('task_id',candidate.id,'revision',candidate.revision,
     'assignee_actor_ref_id',candidate.planned_assignee_actor_ref_id));
 end loop;
 if not targets @> jsonb_build_array(jsonb_build_object('task_id',p_task_id)) then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
 reply_due:=private.fn_propose_request_reply_due_v1(t.due_at,now());
 insert into public.requests(household_id,requester_id,recipient_id,requester_actor_ref_id,recipient_actor_ref_id,
   request_kind,shared_title,shared_message,due_at,status,assignment_task_instance_id,assignment_scope)
 values(hh,p_actor_id,p_recipient_user_id,actor_ref,recipient_ref,'assignment_change',t.title,p_shared_message,t.due_at,'pending',p_task_id,p_scope)
 returning id into request_id;
 insert into public.request_attempts(household_id,request_id,attempt_kind,state,terms_revision,terms,reply_due_at,created_by_actor_ref_id)
 values(hh,request_id,'initial','pending',1,jsonb_build_object('title',t.title,'due_at',t.due_at,
   'scope',p_scope,'assignment_targets',targets),reply_due,actor_ref) returning id into attempt_id;
 perform private.fn_emit_notification_intent_v1(hh,p_actor_id,actor_ref,null,recipient_ref,'request.received','担当変更のお願い',
   coalesce(p_shared_message,t.title),jsonb_build_object('request_id',request_id,'attempt_id',attempt_id,
     'revision',1,'terms_revision',1,'request_kind','assignment_change','scope',p_scope,'reply_due_at',reply_due,'due_at',t.due_at),
   'request:received:'||request_id::text,'immediate','normal','request:'||request_id::text,reply_due,'request',request_id,1);
 result:=jsonb_build_object('request_id',request_id,'attempt_id',attempt_id,'revision',1,'terms_revision',1,'state','pending','reply_due_at',reply_due,'task_id',p_task_id);
 perform private.fn_complete_canonical_operation_v1((claim->>'receipt_id')::uuid,'request',request_id,result);
 return result;
end; $$;
revoke all on function public.server_tx_create_assignment_change_request(uuid,uuid,uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.server_tx_create_assignment_change_request(uuid,uuid,uuid,uuid,text,text) to service_role;

-- Old ID-only acceptance has no trustworthy observed revision. Never upgrade
-- an old action to the latest revision on behalf of the user.
create or replace function public.server_tx_accept_assignment_change_request(p_actor_id uuid,p_operation_id uuid,p_request_id uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
begin
 perform private.fn_require_production_actor_context_v1(p_actor_id);
 raise exception 'REQUEST_ATTEMPT_STALE: reopen the request and confirm current terms';
end; $$;

create or replace function public.server_tx_transition_request_v2(
 p_actor_id uuid,p_operation_id uuid,p_request_id uuid,p_attempt_id uuid,p_action text,
 p_terms jsonb,p_expected_revision bigint,p_expected_terms_revision integer,p_source text
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare c jsonb;
begin
 c:=private.fn_require_production_actor_context_v1(p_actor_id);
 return private.fn_command_transition_request_attempt_v1((c->>'household_id')::uuid,p_actor_id,
   (c->>'actor_ref_id')::uuid,null,p_request_id,p_attempt_id,p_action,p_terms,
   p_expected_revision,p_expected_terms_revision,p_operation_id,p_source);
end; $$;
revoke all on function public.server_tx_transition_request_v2(uuid,uuid,uuid,uuid,text,jsonb,bigint,integer,text) from public,anon,authenticated;
grant execute on function public.server_tx_transition_request_v2(uuid,uuid,uuid,uuid,text,jsonb,bigint,integer,text) to service_role;

-- Issue #54 request-form parity: initial light Requests need a response deadline
-- distinct from the work deadline. Preserve the public server_tx_send_request
-- shape for existing callers and add a v2 overload used by PWA/LINE adapters.

create or replace function private.fn_command_create_light_request_v2(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_requester_actor_ref_id uuid,
  p_test_context_id uuid,
  p_recipient_actor_ref_id uuid,
  p_shared_title text,
  p_shared_message text,
  p_due_at timestamptz,
  p_reply_due_at timestamptz,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_request_id uuid;
  v_attempt_id uuid;
  v_requester_user uuid;
  v_recipient_user uuid;
  v_result jsonb;
  v_reply_due timestamptz;
begin
  if nullif(btrim(coalesce(p_shared_title, '')), '') is null then raise exception 'REQUEST_TITLE_REQUIRED'; end if;
  if p_requester_actor_ref_id = p_recipient_actor_ref_id then raise exception 'REQUEST_PARTIES_MUST_DIFFER'; end if;
  if p_source not in ('line', 'pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;


  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id, p_operator_user_id, p_requester_actor_ref_id, p_test_context_id,
    p_operation_id, 'request.create.light',
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'recipient_actor_ref_id', p_recipient_actor_ref_id,
      'shared_title', btrim(p_shared_title),
      'shared_message', nullif(btrim(coalesce(p_shared_message, '')), ''),
      'due_at', p_due_at, 'reply_due_at', p_reply_due_at, 'source', p_source
    ))
  );
  if v_claim->>'disposition' = 'replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;
  if p_reply_due_at <= now() then raise exception 'REQUEST_REPLY_DUE_IN_PAST'; end if;
  v_reply_due:=coalesce(p_reply_due_at,private.fn_propose_request_reply_due_v1(p_due_at,now()));

  perform private.fn_assert_actor_ref_scope(p_household_id, p_recipient_actor_ref_id, p_test_context_id);
  v_requester_user := private.fn_legacy_user_for_actor_ref_v1(p_household_id, p_requester_actor_ref_id, p_test_context_id);
  v_recipient_user := private.fn_legacy_user_for_actor_ref_v1(p_household_id, p_recipient_actor_ref_id, p_test_context_id);

  insert into public.requests (
    household_id, requester_id, recipient_id, requester_actor_ref_id,
    recipient_actor_ref_id, request_kind, shared_title, shared_message,
    due_at, status, test_context_id
  ) values (
    p_household_id, v_requester_user, v_recipient_user, p_requester_actor_ref_id,
    p_recipient_actor_ref_id, 'light', btrim(p_shared_title),
    nullif(btrim(coalesce(p_shared_message, '')), ''), p_due_at, 'pending', p_test_context_id
  ) returning id into v_request_id;

  insert into public.request_attempts (
    household_id, request_id, attempt_kind, state, terms_revision, terms,
    reply_due_at, created_by_actor_ref_id, test_context_id
  ) values (
    p_household_id, v_request_id, 'initial', 'pending', 1,
    jsonb_build_object('title', btrim(p_shared_title), 'due_at', p_due_at),
    v_reply_due, p_requester_actor_ref_id, p_test_context_id
  ) returning id into v_attempt_id;

  perform private.fn_emit_notification_intent_v1(
    p_household_id, p_operator_user_id, p_requester_actor_ref_id, p_test_context_id,
    p_recipient_actor_ref_id, 'request.received', 'お願いが届きました',
    btrim(p_shared_title),
    jsonb_build_object('request_id', v_request_id, 'attempt_id', v_attempt_id,
      'reply_due_at', v_reply_due, 'due_at', p_due_at),
    'request:received:' || v_request_id::text,
    'immediate', 'normal', 'request:' || v_request_id::text,
    v_reply_due, 'request', v_request_id, 1
  );

  v_result := jsonb_build_object(
    'request_id', v_request_id, 'attempt_id', v_attempt_id,
    'state', 'pending', 'terms_revision', 1,
    'reply_due_at', v_reply_due, 'due_at', p_due_at
  );
  perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'request', v_request_id, v_result);
  return v_result;
end;
$$;
revoke all on function private.fn_command_create_light_request_v2(uuid,uuid,uuid,uuid,uuid,text,text,timestamptz,timestamptz,uuid,text) from public, anon, authenticated;
grant execute on function private.fn_command_create_light_request_v2(uuid,uuid,uuid,uuid,uuid,text,text,timestamptz,timestamptz,uuid,text) to service_role;


create or replace function private.fn_command_create_light_request_v1(
 p_household_id uuid,p_operator_user_id uuid,p_requester_actor_ref_id uuid,p_test_context_id uuid,
 p_recipient_actor_ref_id uuid,p_shared_title text,p_shared_message text,p_due_at timestamptz,p_operation_id uuid,p_source text
) returns jsonb language sql security invoker set search_path = '' as $$
 select private.fn_command_create_light_request_v2(p_household_id,p_operator_user_id,p_requester_actor_ref_id,p_test_context_id,
 p_recipient_actor_ref_id,p_shared_title,p_shared_message,p_due_at,null,p_operation_id,p_source)
$$;

create or replace function public.server_tx_accept_request(
  p_actor_id uuid, p_operation_id uuid, p_request_id uuid
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_attempt public.request_attempts%rowtype;
  v_result jsonb;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  if exists(select 1 from public.requests where id=p_request_id and request_kind='assignment_change') then
    raise exception 'REQUEST_ATTEMPT_STALE';
  end if;

  v_household_id := (v_context->>'household_id')::uuid;
  v_actor_ref_id := (v_context->>'actor_ref_id')::uuid;
  select a.* into v_attempt from public.request_attempts a
  where a.household_id = v_household_id and a.request_id = p_request_id
    and a.test_context_id is null
    and a.state in ('pending', 'checking', 'consulting', 'awaiting_confirmation')
  order by a.created_at desc limit 1;
  if not found then raise exception 'REQUEST_NOT_PENDING'; end if;
  v_result := private.fn_command_transition_request_attempt_v1(
    v_household_id, p_actor_id, v_actor_ref_id, null, p_request_id,
    v_attempt.id,
    case when v_attempt.state in ('consulting', 'awaiting_confirmation')
      then 'confirm_terms' else 'accept' end,
    null, v_attempt.revision,
    v_attempt.terms_revision, p_operation_id, 'pwa'
  );
  return v_result || jsonb_build_object('task_id', v_result->'linked_task_id');
end;
$$;

create or replace function public.server_tx_decline_request(
  p_actor_id uuid, p_operation_id uuid, p_request_id uuid
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_attempt public.request_attempts%rowtype;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  if exists(select 1 from public.requests where id=p_request_id and request_kind='assignment_change') then
    raise exception 'REQUEST_ATTEMPT_STALE';
  end if;

  v_household_id := (v_context->>'household_id')::uuid;
  v_actor_ref_id := (v_context->>'actor_ref_id')::uuid;
  select a.* into v_attempt from public.request_attempts a
  where a.household_id = v_household_id and a.request_id = p_request_id
    and a.test_context_id is null
    and a.state in ('pending', 'checking', 'consulting', 'awaiting_confirmation')
  order by a.created_at desc limit 1;
  if not found then raise exception 'REQUEST_NOT_PENDING'; end if;
  if v_attempt.attempt_kind in ('change', 'cancel') then
    return private.fn_command_decline_request_followup_v1(
      v_household_id, p_actor_id, v_actor_ref_id, null, p_request_id,
      v_attempt.id, v_attempt.revision, p_operation_id, 'pwa'
    );
  end if;
  return private.fn_command_transition_request_attempt_v1(
      v_household_id, p_actor_id, v_actor_ref_id, null, p_request_id,
      v_attempt.id, 'decline', null, v_attempt.revision,
      v_attempt.terms_revision, p_operation_id, 'pwa'
    );
end;
$$;

create or replace function public.server_tx_cancel_request(
  p_actor_id uuid, p_operation_id uuid, p_request_id uuid
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_request public.requests%rowtype;
  v_attempt public.request_attempts%rowtype;
  v_task_revision bigint;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  if exists(select 1 from public.requests where id=p_request_id and request_kind='assignment_change') then
    raise exception 'REQUEST_ATTEMPT_STALE';
  end if;

  v_household_id := (v_context->>'household_id')::uuid;
  v_actor_ref_id := (v_context->>'actor_ref_id')::uuid;
  select * into v_request from public.requests r
  where r.household_id = v_household_id and r.id = p_request_id;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.requester_actor_ref_id <> v_actor_ref_id then
    raise exception 'REQUEST_CANCEL_NOT_ALLOWED';
  end if;

  if exists (
    select 1 from public.request_attempts a
    where a.request_id = p_request_id and a.attempt_kind in ('initial', 'reproposal')
      and a.state = 'accepted'
  ) then
    select revision into v_task_revision from public.task_instances
    where household_id = v_household_id and id = v_request.linked_task_instance_id;
    return private.fn_command_start_request_followup_v1(
      v_household_id, p_actor_id, v_actor_ref_id, null, p_request_id,
      'cancel', null, null, v_request.due_at, v_request.revision,
      v_task_revision, p_operation_id, 'pwa'
    );
  end if;

  select a.* into v_attempt from public.request_attempts a
  where a.household_id = v_household_id and a.request_id = p_request_id
    and a.test_context_id is null
    and a.state in ('pending', 'checking', 'consulting', 'awaiting_confirmation')
  order by a.created_at desc limit 1;
  if not found then raise exception 'REQUEST_NOT_PENDING'; end if;
  return private.fn_command_transition_request_attempt_v1(
    v_household_id, p_actor_id, v_actor_ref_id, null, p_request_id,
    v_attempt.id, 'cancel', null, v_attempt.revision,
    v_attempt.terms_revision, p_operation_id, 'pwa'
  );
end;
$$;

create or replace function public.server_tx_negotiate_request_v1(
 p_actor_id uuid,p_operation_id uuid,p_request_id uuid,p_attempt_id uuid,p_action text,
 p_terms jsonb default null,p_expected_revision bigint default null,p_expected_terms_revision integer default null
) returns jsonb language sql security invoker set search_path = '' as $$
 select public.server_tx_transition_request_v2(p_actor_id,p_operation_id,p_request_id,p_attempt_id,p_action,p_terms,
 p_expected_revision,p_expected_terms_revision,'pwa')
$$;
create or replace function public.server_tx_confirm_request_draft_v2(
  p_actor_id uuid,
  p_operation_id uuid,
  p_raw_input_id uuid,
  p_recipient_user_id uuid,
  p_shared_title text,
  p_confirmed_message text,
  p_due_at timestamptz,
  p_reply_due_at timestamptz
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_raw_input record;
  v_sub_operation_id uuid;
  v_inner_result jsonb;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_raw_input_id is null
     or p_recipient_user_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if coalesce(btrim(p_shared_title), '') = '' or coalesce(btrim(p_confirmed_message), '') = '' then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'confirm-request-draft|' || p_raw_input_id::text || '|' || p_recipient_user_id::text
        || '|' || p_shared_title || '|' || p_confirmed_message || '|' || coalesce(p_due_at::text,'') || '|' || coalesce(p_reply_due_at::text,''),
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'confirm-request-draft', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;

    if found then
      exit;
    end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;

    if found then
      if v_receipt.request_hash <> v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  -- Only the raw_input's own author may confirm it (private per-author text,
  -- never exposed to other household members even within the same
  -- household — docs/design/v6/04_SECURITY_RLS_PRIVACY.md #9). A mismatched
  -- household or a different author both look like "not found" rather than
  -- leaking existence.
  select * into v_raw_input
  from private.raw_inputs
  where id = p_raw_input_id and household_id = v_household_id and author_user_id = p_actor_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_raw_input.kind <> 'request_draft' then
    raise exception 'INVALID_INPUT';
  end if;
  if v_raw_input.expires_at <= now() then
    raise exception 'RAW_INPUT_EXPIRED';
  end if;

  v_sub_operation_id := md5(p_operation_id::text || ':server_tx_send_request')::uuid;

  v_inner_result := public.server_tx_send_request_v2(
    p_actor_id, v_sub_operation_id, p_recipient_user_id, p_shared_title, p_confirmed_message, p_due_at, p_reply_due_at
  );

  v_result := v_inner_result;

  update private.mutation_receipts
  set result_type = 'request', result_id = (v_inner_result->>'request_id')::uuid, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_confirm_request_draft_v2(uuid,uuid,uuid,uuid,text,text,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.server_tx_confirm_request_draft_v2(uuid,uuid,uuid,uuid,text,text,timestamptz,timestamptz) to service_role;

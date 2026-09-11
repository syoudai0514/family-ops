-- XC-03 / XC-05 final convergence.
--
-- 1. Initial/reproposal consultation may carry a *structured* material patch.
--    Free-form `candidate`/memo text is never interpreted as a Task mutation.
-- 2. The canonical RequestAttempt command remains the agreement owner.  Once
--    both parties confirm the same terms revision, this adapter applies the
--    structured work-date/time patch in the SAME transaction as acceptance.
-- 3. Assignment-change requests keep their server-issued task/revision scope;
--    the material patch may only describe that exact reassignment to the
--    request recipient.  Existing fn_apply_request_assignment_v1 performs the
--    actual assignment CAS before this work-deadline patch runs.
-- 4. Expired requests get a canonical, revision-checked reproposal command so
--    LINE does not need a second request lifecycle.

create or replace function private.fn_validate_initial_request_material_patch_v1(
  p_household_id uuid,
  p_request_id uuid,
  p_attempt_kind text,
  p_terms jsonb
) returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_request public.requests%rowtype;
  v_patch jsonb;
  v_assignment jsonb;
  v_targets jsonb;
  v_due timestamptz;
  v_date date;
begin
  if p_attempt_kind not in ('initial', 'reproposal') then return; end if;
  if p_terms is null or jsonb_typeof(p_terms) <> 'object' then raise exception 'REQUEST_TERMS_REQUIRED'; end if;
  if not (p_terms ? 'material_patch') then return; end if;

  v_patch := p_terms->'material_patch';
  if jsonb_typeof(v_patch) <> 'object' then raise exception 'REQUEST_MATERIAL_PATCH_INVALID'; end if;
  if exists (
    select 1 from jsonb_object_keys(v_patch) k
    where k not in ('version', 'work_due_at', 'scheduled_date', 'assignment')
  ) then raise exception 'REQUEST_MATERIAL_PATCH_FIELD_INVALID'; end if;
  if coalesce((v_patch->>'version')::int, 0) <> 1 then raise exception 'REQUEST_MATERIAL_PATCH_VERSION_INVALID'; end if;

  select * into v_request from public.requests
  where household_id = p_household_id and id = p_request_id;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;

  if v_patch ? 'work_due_at' then
    if jsonb_typeof(v_patch->'work_due_at') <> 'string'
       or nullif(btrim(v_patch->>'work_due_at'), '') is null then
      raise exception 'REQUEST_MATERIAL_DUE_INVALID';
    end if;
    v_due := (v_patch->>'work_due_at')::timestamptz;
    if v_due <= now() then raise exception 'REQUEST_MATERIAL_DUE_IN_PAST'; end if;
  end if;

  if v_patch ? 'scheduled_date' then
    if jsonb_typeof(v_patch->'scheduled_date') <> 'string'
       or nullif(btrim(v_patch->>'scheduled_date'), '') is null then
      raise exception 'REQUEST_MATERIAL_DATE_INVALID';
    end if;
    v_date := (v_patch->>'scheduled_date')::date;
  elsif v_due is not null then
    v_date := (v_due at time zone 'Asia/Tokyo')::date;
  end if;

  if v_request.request_kind = 'assignment_change' then
    v_targets := p_terms->'assignment_targets';
    if v_targets is null or jsonb_typeof(v_targets) <> 'array' or jsonb_array_length(v_targets) = 0 then
      raise exception 'REQUEST_ASSIGNMENT_REPROPOSAL_REQUIRED';
    end if;
    v_assignment := v_patch->'assignment';
    if v_assignment is null or jsonb_typeof(v_assignment) <> 'object'
       or v_assignment->>'mode' <> 'request_recipient'
       or v_assignment->'targets' is distinct from v_targets then
      raise exception 'REQUEST_MATERIAL_ASSIGNMENT_INVALID';
    end if;
    if exists (
      select 1 from jsonb_object_keys(v_assignment) k
      where k not in ('mode', 'targets')
    ) then raise exception 'REQUEST_MATERIAL_ASSIGNMENT_INVALID'; end if;
    -- One shared work deadline cannot safely rewrite a multi-occurrence weekly
    -- scope.  The assignment itself still supports this_week; a date/time
    -- change must be represented per occurrence by a later canonical change.
    if v_due is not null and jsonb_array_length(v_targets) <> 1 then
      raise exception 'REQUEST_MATERIAL_DUE_REQUIRES_SINGLE_TARGET';
    end if;
  elsif v_request.request_kind = 'light' then
    if v_patch ? 'assignment' then raise exception 'REQUEST_MATERIAL_ASSIGNMENT_INVALID'; end if;
  else
    raise exception 'REQUEST_KIND_INVALID';
  end if;
end;
$$;

revoke all on function private.fn_validate_initial_request_material_patch_v1(uuid,uuid,text,jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_validate_initial_request_material_patch_v1(uuid,uuid,text,jsonb)
  to service_role;

create or replace function private.fn_request_attempt_material_patch_guard_v1()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.fn_validate_initial_request_material_patch_v1(
    new.household_id, new.request_id, new.attempt_kind, new.terms
  );
  return new;
end;
$$;

revoke all on function private.fn_request_attempt_material_patch_guard_v1()
  from public, anon, authenticated;
grant execute on function private.fn_request_attempt_material_patch_guard_v1()
  to service_role;

drop trigger if exists request_attempt_material_patch_guard_v1 on public.request_attempts;
create trigger request_attempt_material_patch_guard_v1
  before insert or update of terms on public.request_attempts
  for each row execute function private.fn_request_attempt_material_patch_guard_v1();

create or replace function private.fn_apply_confirmed_initial_material_patch_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_request_id uuid,
  p_attempt_id uuid,
  p_source text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.requests%rowtype;
  v_attempt public.request_attempts%rowtype;
  v_patch jsonb;
  v_due timestamptz;
  v_date date;
  v_task public.task_instances%rowtype;
  v_target jsonb;
  v_target_id uuid;
  v_existing_event boolean;
  v_task_revision bigint;
begin
  select * into v_request from public.requests
  where household_id = p_household_id and id = p_request_id for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;

  select * into v_attempt from public.request_attempts
  where household_id = p_household_id and id = p_attempt_id and request_id = p_request_id for update;
  if not found then raise exception 'REQUEST_ATTEMPT_NOT_FOUND'; end if;
  if v_attempt.state <> 'accepted' or v_attempt.attempt_kind not in ('initial', 'reproposal') then
    return jsonb_build_object('applied', false);
  end if;

  perform private.fn_validate_initial_request_material_patch_v1(
    p_household_id, p_request_id, v_attempt.attempt_kind, v_attempt.terms
  );
  v_patch := v_attempt.terms->'material_patch';
  if v_patch is null then return jsonb_build_object('applied', false); end if;

  v_due := nullif(v_patch->>'work_due_at', '')::timestamptz;
  v_date := nullif(v_patch->>'scheduled_date', '')::date;
  if v_date is null and v_due is not null then
    v_date := (v_due at time zone 'Asia/Tokyo')::date;
  end if;

  if v_request.request_kind = 'assignment_change' then
    v_target := (v_attempt.terms->'assignment_targets')->0;
    v_target_id := (v_target->>'task_id')::uuid;
  else
    v_target_id := v_request.linked_task_instance_id;
  end if;
  if v_target_id is null then raise exception 'REQUEST_ACCEPTED_TASK_REQUIRED'; end if;

  select exists(
    select 1 from public.task_events e
    where e.household_id = p_household_id
      and e.task_instance_id = v_target_id
      and e.idempotency_key = 'request-material-patch:' || p_attempt_id::text
  ) into v_existing_event;
  if v_existing_event then
    select * into v_task from public.task_instances
      where household_id = p_household_id and id = v_target_id;
    return jsonb_build_object(
      'applied', true, 'replay', true, 'task_id', v_target_id,
      'task_revision', v_task.revision, 'work_due_at', v_task.due_at,
      'scheduled_date', v_task.scheduled_date
    );
  end if;

  select * into v_task from public.task_instances
  where household_id = p_household_id and id = v_target_id for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if v_task.test_context_id is distinct from v_request.test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_task.status not in ('todo', 'in_progress') then raise exception 'TASK_NOT_OPEN'; end if;

  -- Assignment-change CAS is owned by fn_apply_request_assignment_v1 and has
  -- already checked the exact server-issued revision before this point.  For a
  -- light request this Task was just created in this transaction.
  if v_due is not null or v_date is not null then
    update public.task_instances
    set due_at = coalesce(v_due, due_at),
        scheduled_date = coalesce(v_date, scheduled_date),
        revision = revision + 1
    where household_id = p_household_id and id = v_target_id
    returning revision into v_task_revision;
  else
    v_task_revision := v_task.revision;
  end if;

  if v_due is not null then
    update public.requests
    set due_at = v_due,
        revision = revision + 1
    where household_id = p_household_id and id = p_request_id;
  end if;

  insert into public.task_events(
    household_id, task_instance_id, actor_id, actor_ref_id, test_context_id,
    event_type, payload, source, idempotency_key
  ) values(
    p_household_id, v_target_id,
    case when v_request.test_context_id is null then p_operator_user_id else null end,
    p_actor_ref_id, v_request.test_context_id,
    'edited',
    jsonb_build_object(
      'request_id', p_request_id,
      'attempt_id', p_attempt_id,
      'terms_revision', v_attempt.terms_revision,
      'material_patch', v_patch,
      'revision', v_task_revision
    ),
    p_source,
    'request-material-patch:' || p_attempt_id::text
  );

  return jsonb_build_object(
    'applied', true, 'task_id', v_target_id,
    'task_revision', v_task_revision, 'work_due_at', v_due,
    'scheduled_date', v_date
  );
end;
$$;

revoke all on function private.fn_apply_confirmed_initial_material_patch_v1(uuid,uuid,uuid,uuid,uuid,text)
  from public, anon, authenticated;
grant execute on function private.fn_apply_confirmed_initial_material_patch_v1(uuid,uuid,uuid,uuid,uuid,text)
  to service_role;

-- Keep the public adapter thin: the existing private command still owns all
-- RequestAttempt transition, confirmation, assignment and receipt semantics.
-- The material Task patch joins the same SQL transaction after successful
-- acceptance, so any stale/conflict error rolls the whole agreement back.
create or replace function public.server_tx_transition_request_v2(
  p_actor_id uuid,
  p_operation_id uuid,
  p_request_id uuid,
  p_attempt_id uuid,
  p_action text,
  p_terms jsonb,
  p_expected_revision bigint,
  p_expected_terms_revision integer,
  p_source text
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c jsonb;
  v_result jsonb;
  v_patch_result jsonb;
begin
  c := private.fn_require_production_actor_context_v1(p_actor_id);
  v_result := private.fn_command_transition_request_attempt_v1(
    (c->>'household_id')::uuid,
    p_actor_id,
    (c->>'actor_ref_id')::uuid,
    null,
    p_request_id,
    p_attempt_id,
    p_action,
    p_terms,
    p_expected_revision,
    p_expected_terms_revision,
    p_operation_id,
    p_source
  );

  if v_result->>'state' = 'accepted' then
    v_patch_result := private.fn_apply_confirmed_initial_material_patch_v1(
      (c->>'household_id')::uuid,
      p_actor_id,
      (c->>'actor_ref_id')::uuid,
      p_request_id,
      p_attempt_id,
      p_source
    );
    if coalesce((v_patch_result->>'applied')::boolean, false) then
      v_result := v_result || jsonb_build_object('material_patch', v_patch_result);
    end if;
  end if;

  return v_result;
end;
$$;

revoke all on function public.server_tx_transition_request_v2(uuid,uuid,uuid,uuid,text,jsonb,bigint,integer,text)
  from public, anon, authenticated;
grant execute on function public.server_tx_transition_request_v2(uuid,uuid,uuid,uuid,text,jsonb,bigint,integer,text)
  to service_role;

create or replace function public.server_tx_repropose_request_v1(
  p_actor_id uuid,
  p_operation_id uuid,
  p_request_id uuid,
  p_expected_request_revision bigint,
  p_reply_due_at timestamptz,
  p_source text
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_request public.requests%rowtype;
  v_old public.request_attempts%rowtype;
  v_attempt_id uuid;
  v_claim jsonb;
  v_receipt_id uuid;
  v_request_revision bigint;
  v_result jsonb;
begin
  if p_source not in ('line', 'pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  if p_reply_due_at is null or p_reply_due_at <= now() then raise exception 'REQUEST_REPLY_DUE_IN_PAST'; end if;
  c := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (c->>'household_id')::uuid;
  v_actor_ref_id := (c->>'actor_ref_id')::uuid;

  v_claim := private.fn_claim_canonical_operation_v1(
    v_household_id, p_actor_id, v_actor_ref_id, null, p_operation_id,
    'request.reproposal',
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'request_id', p_request_id,
      'expected_request_revision', p_expected_request_revision,
      'reply_due_at', p_reply_due_at,
      'source', p_source
    ))
  );
  if v_claim->>'disposition' = 'replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_request from public.requests
  where household_id = v_household_id and id = p_request_id for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.requester_actor_ref_id is distinct from v_actor_ref_id then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
  if v_request.test_context_id is not null then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_request.revision <> p_expected_request_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;

  select * into v_old from public.request_attempts
  where household_id = v_household_id and request_id = p_request_id
    and attempt_kind in ('initial', 'reproposal')
  order by created_at desc, id desc
  limit 1 for update;
  if not found or v_old.state <> 'expired' then raise exception 'REQUEST_REPROPOSAL_NOT_ALLOWED'; end if;
  if exists (
    select 1 from public.request_attempts
    where household_id = v_household_id and request_id = p_request_id
      and state in ('pending','checking','consulting','awaiting_confirmation')
  ) then raise exception 'REQUEST_REPROPOSAL_NOT_ALLOWED'; end if;

  perform private.fn_validate_initial_request_material_patch_v1(
    v_household_id, p_request_id, 'reproposal', v_old.terms
  );

  insert into public.request_attempts(
    household_id, request_id, attempt_kind, state, terms_revision, terms,
    reply_due_at, created_by_actor_ref_id, test_context_id
  ) values(
    v_household_id, p_request_id, 'reproposal', 'pending', 1, v_old.terms,
    p_reply_due_at, v_actor_ref_id, null
  ) returning id into v_attempt_id;

  update public.requests
  set status = 'pending', revision = revision + 1
  where household_id = v_household_id and id = p_request_id
  returning revision into v_request_revision;
  perform private.fn_project_request_legacy_lifecycle_v1(v_household_id, p_request_id);

  perform private.fn_emit_notification_intent_v1(
    v_household_id, p_actor_id, v_actor_ref_id, null,
    v_request.recipient_actor_ref_id,
    'request.reproposed',
    'お願いを再提案しました',
    v_request.shared_title,
    jsonb_build_object(
      'request_id', p_request_id, 'attempt_id', v_attempt_id,
      'revision', 1, 'terms_revision', 1,
      'reply_due_at', p_reply_due_at, 'due_at', v_request.due_at
    ),
    'request:reproposal:' || v_attempt_id::text,
    'immediate', 'normal', 'request:' || p_request_id::text,
    p_reply_due_at, 'request', p_request_id, v_request_revision
  );

  v_result := jsonb_build_object(
    'request_id', p_request_id, 'attempt_id', v_attempt_id,
    'state', 'pending', 'revision', 1, 'terms_revision', 1,
    'request_revision', v_request_revision,
    'reply_due_at', p_reply_due_at
  );
  perform private.fn_complete_canonical_operation_v1(
    v_receipt_id, 'request', p_request_id, v_result
  );
  return v_result;
end;
$$;

revoke all on function public.server_tx_repropose_request_v1(uuid,uuid,uuid,bigint,timestamptz,text)
  from public, anon, authenticated;
grant execute on function public.server_tx_repropose_request_v1(uuid,uuid,uuid,bigint,timestamptz,text)
  to service_role;

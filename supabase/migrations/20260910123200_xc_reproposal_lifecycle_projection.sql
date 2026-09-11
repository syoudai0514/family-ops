-- XC-03/XC-05 convergence follow-up.
--
-- Reproposal reopens an expired RequestAttempt.  The legacy `requests` tuple is
-- a CURRENT projection, while immutable lifecycle history lives in
-- `request_attempts`.  Reopening therefore has to clear the prior terminal
-- timestamps together with `status = pending`.  The previous adapter changed
-- only status, violating requests_check1, then called the projector and would
-- have incremented the Request revision a second time.
--
-- Keep one revision increment for this canonical command and return that exact
-- revision to LINE/PWA callers and notification metadata.

create or replace function public.server_tx_repropose_request_v1(
  p_actor_id uuid,
  p_operation_id uuid,
  p_request_id uuid,
  p_expected_request_revision bigint,
  p_reply_due_at timestamptz,
  p_source text
) returns jsonb
language plpgsql
security definer
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

  -- `requests` is the current compatibility projection.  Reopening must clear
  -- every terminal timestamp from the expired lifecycle in the same write.
  -- Do not call fn_project_request_legacy_lifecycle_v1 afterwards: that would
  -- apply a second Request revision for this single canonical command.
  update public.requests
  set status = 'pending',
      accepted_at = null,
      declined_at = null,
      cancelled_at = null,
      completed_at = null,
      closed_at = null,
      revision = revision + 1
  where household_id = v_household_id and id = p_request_id
  returning revision into v_request_revision;

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

-- WP-DD4 canonical Request adapter/cutover.
--
-- Existing Edge/LINE callers keep their public server_tx_* signatures, but
-- every mutation is now routed through the DD3 ActorRef/receipt/revision
-- command layer. Post-accept changes/cancellation are new Attempts; the
-- accepted legacy Request tuple remains stable while negotiation is pending.

create or replace function private.fn_require_production_actor_context_v1(
  p_actor_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_actor_ref_id uuid;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;

  select m.household_id into v_household_id
  from public.household_members m
  where m.user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select a.id into v_actor_ref_id
  from public.domain_actor_refs a
  where a.household_id = v_household_id
    and a.actor_kind = 'real_user'
    and a.real_user_id = p_actor_id;
  if v_actor_ref_id is null then raise exception 'REAL_ACTOR_REF_NOT_FOUND'; end if;

  return jsonb_build_object(
    'household_id', v_household_id,
    'actor_ref_id', v_actor_ref_id
  );
end;
$$;
revoke all on function private.fn_require_production_actor_context_v1(uuid)
  from public, anon, authenticated;
grant execute on function private.fn_require_production_actor_context_v1(uuid)
  to service_role;

create or replace function private.fn_validate_post_accept_request_terms_v1(
  p_household_id uuid,
  p_test_context_id uuid,
  p_attempt_kind text,
  p_terms jsonb
) returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_patch jsonb;
  v_mode text;
  v_assignee uuid;
begin
  if p_attempt_kind not in ('change', 'cancel') then
    raise exception 'REQUEST_FOLLOWUP_KIND_INVALID';
  end if;
  if p_terms is null or jsonb_typeof(p_terms) <> 'object'
     or nullif(p_terms->>'target_task_revision', '') is null then
    raise exception 'REQUEST_TERMS_REQUIRED';
  end if;

  perform (p_terms->>'target_task_revision')::bigint;

  if p_attempt_kind = 'cancel' then
    return;
  end if;

  v_patch := p_terms->'task_patch';
  if v_patch is null or jsonb_typeof(v_patch) <> 'object' or v_patch = '{}'::jsonb then
    raise exception 'REQUEST_TERMS_REQUIRED';
  end if;
  if exists (
    select 1 from jsonb_object_keys(v_patch) k
    where k not in ('title', 'due_at', 'scheduled_date', 'assignment_mode', 'assignee_actor_ref_id')
  ) then
    raise exception 'REQUEST_TERMS_FIELD_INVALID';
  end if;

  if v_patch ? 'title' and nullif(btrim(coalesce(v_patch->>'title', '')), '') is null then
    raise exception 'REQUEST_TITLE_REQUIRED';
  end if;
  if v_patch ? 'due_at' and jsonb_typeof(v_patch->'due_at') not in ('string', 'null') then
    raise exception 'REQUEST_TERMS_FIELD_INVALID';
  end if;
  if v_patch ? 'scheduled_date' then
    if jsonb_typeof(v_patch->'scheduled_date') <> 'string' then
      raise exception 'REQUEST_TERMS_FIELD_INVALID';
    end if;
    perform (v_patch->>'scheduled_date')::date;
  end if;

  if v_patch ? 'assignment_mode' then
    v_mode := v_patch->>'assignment_mode';
    if v_mode not in ('person', 'unassigned', 'anyone') then
      raise exception 'ASSIGNMENT_MODE_INVALID';
    end if;
    v_assignee := nullif(v_patch->>'assignee_actor_ref_id', '')::uuid;
    if (v_mode = 'person' and v_assignee is null)
       or (v_mode <> 'person' and v_assignee is not null) then
      raise exception 'ASSIGNMENT_MODE_ACTOR_MISMATCH';
    end if;
    perform private.fn_assert_actor_ref_scope(
      p_household_id, v_assignee, p_test_context_id
    );
  elsif v_patch ? 'assignee_actor_ref_id' then
    raise exception 'ASSIGNMENT_MODE_REQUIRED';
  end if;
end;
$$;
revoke all on function private.fn_validate_post_accept_request_terms_v1(uuid, uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_validate_post_accept_request_terms_v1(uuid, uuid, text, jsonb)
  to service_role;

create or replace function private.fn_apply_accepted_request_followup_v1()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.requests%rowtype;
  v_task public.task_instances%rowtype;
  v_patch jsonb;
  v_mode text;
  v_assignee_ref uuid;
  v_assignee_user uuid;
  v_actor_user uuid;
  v_resolver_actor_ref uuid;
  v_task_revision bigint;
begin
  if new.state <> 'accepted'
     or old.state = 'accepted'
     or new.attempt_kind not in ('change', 'cancel') then
    return new;
  end if;

  perform private.fn_validate_post_accept_request_terms_v1(
    new.household_id, new.test_context_id, new.attempt_kind, new.terms
  );

  select * into v_request
  from public.requests r
  where r.household_id = new.household_id and r.id = new.request_id
  for update;
  if not found or v_request.linked_task_instance_id is null then
    raise exception 'REQUEST_ACCEPTED_TASK_REQUIRED';
  end if;

  select * into v_task
  from public.task_instances t
  where t.household_id = new.household_id
    and t.id = v_request.linked_task_instance_id
  for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if v_task.test_context_id is distinct from new.test_context_id then
    raise exception 'ACTOR_SCOPE_CONFLICT';
  end if;
  if v_task.revision <> (new.terms->>'target_task_revision')::bigint then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  if v_task.status not in ('todo', 'in_progress') then
    raise exception 'TASK_NOT_OPEN';
  end if;

  select c.actor_ref_id into v_resolver_actor_ref
  from public.request_attempt_confirmations c
  where c.household_id = new.household_id
    and c.attempt_id = new.id
    and c.terms_revision = new.terms_revision
  order by c.confirmed_at desc, c.actor_ref_id desc
  limit 1;
  v_resolver_actor_ref := coalesce(v_resolver_actor_ref, new.created_by_actor_ref_id);
  v_actor_user := private.fn_legacy_user_for_actor_ref_v1(
    new.household_id, v_resolver_actor_ref, new.test_context_id
  );

  if new.attempt_kind = 'cancel' then
    update public.task_instances
    set status = 'cancelled',
        active_claimant_actor_ref_id = null,
        claimed_at = null,
        attention_state = 'active',
        waiting_note = null,
        next_check_at = null,
        revision = revision + 1
    where id = v_task.id
    returning revision into v_task_revision;

    insert into public.task_events (
      household_id, task_instance_id, actor_id, actor_ref_id, test_context_id,
      event_type, payload, source, idempotency_key
    ) values (
      new.household_id, v_task.id, v_actor_user, v_resolver_actor_ref,
      new.test_context_id, 'cancelled',
      jsonb_build_object('request_id', new.request_id, 'attempt_id', new.id,
        'reason', new.terms->>'reason', 'revision', v_task_revision),
      'canonical_request', 'request-followup:' || new.id::text
    );
  else
    v_patch := new.terms->'task_patch';
    v_mode := case when v_patch ? 'assignment_mode'
      then v_patch->>'assignment_mode' else v_task.assignment_mode end;
    v_assignee_ref := case when v_patch ? 'assignment_mode'
      then nullif(v_patch->>'assignee_actor_ref_id', '')::uuid
      else v_task.planned_assignee_actor_ref_id end;
    v_assignee_user := case when v_assignee_ref is null then null else
      private.fn_legacy_user_for_actor_ref_v1(
        new.household_id, v_assignee_ref, new.test_context_id
      ) end;

    update public.task_instances
    set title = case when v_patch ? 'title' then btrim(v_patch->>'title') else title end,
        due_at = case when v_patch ? 'due_at'
          then nullif(v_patch->>'due_at', '')::timestamptz else due_at end,
        scheduled_date = case when v_patch ? 'scheduled_date'
          then (v_patch->>'scheduled_date')::date else scheduled_date end,
        assignment_mode = v_mode,
        planned_assignee_actor_ref_id = v_assignee_ref,
        planned_assignee_id = case when new.test_context_id is null
          then v_assignee_user else null end,
        assignment_source = case when v_patch ? 'assignment_mode'
          then 'agreement' else assignment_source end,
        active_claimant_actor_ref_id = case when v_mode = 'anyone'
          then active_claimant_actor_ref_id else null end,
        claimed_at = case when v_mode = 'anyone' then claimed_at else null end,
        revision = revision + 1
    where id = v_task.id
    returning revision into v_task_revision;

    insert into public.task_events (
      household_id, task_instance_id, actor_id, actor_ref_id, test_context_id,
      event_type, payload, source, idempotency_key
    ) values (
      new.household_id, v_task.id, v_actor_user, v_resolver_actor_ref,
      new.test_context_id, 'edited',
      jsonb_build_object('request_id', new.request_id, 'attempt_id', new.id,
        'agreed_patch', v_patch, 'revision', v_task_revision),
      'canonical_request', 'request-followup:' || new.id::text
    );
  end if;

  return new;
end;
$$;
revoke all on function private.fn_apply_accepted_request_followup_v1()
  from public, anon, authenticated;
grant execute on function private.fn_apply_accepted_request_followup_v1()
  to service_role;

create trigger request_attempts_apply_accepted_followup_v1
  before update of state on public.request_attempts
  for each row execute function private.fn_apply_accepted_request_followup_v1();

create or replace function private.fn_command_start_request_followup_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_request_id uuid,
  p_attempt_kind text,
  p_task_patch jsonb,
  p_reason text,
  p_reply_due_at timestamptz,
  p_expected_request_revision bigint,
  p_expected_task_revision bigint,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_request public.requests%rowtype;
  v_task public.task_instances%rowtype;
  v_attempt_id uuid;
  v_request_revision bigint;
  v_terms jsonb;
  v_other_actor_ref uuid;
  v_result jsonb;
begin
  if p_attempt_kind not in ('change', 'cancel') then
    raise exception 'REQUEST_FOLLOWUP_KIND_INVALID';
  end if;
  if p_source not in ('line', 'pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
    p_operation_id, 'request.followup.' || p_attempt_kind,
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'request_id', p_request_id, 'attempt_kind', p_attempt_kind,
      'task_patch', coalesce(p_task_patch, '{}'::jsonb), 'reason', p_reason,
      'reply_due_at', p_reply_due_at,
      'expected_request_revision', p_expected_request_revision,
      'expected_task_revision', p_expected_task_revision, 'source', p_source
    ))
  );
  if v_claim->>'disposition' = 'replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_request from public.requests r
  where r.household_id = p_household_id and r.id = p_request_id for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.test_context_id is distinct from p_test_context_id then
    raise exception 'ACTOR_SCOPE_CONFLICT';
  end if;
  perform private.fn_request_party_role_v1(v_request, p_actor_ref_id);
  if v_request.revision <> p_expected_request_revision then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  if not exists (
    select 1 from public.request_attempts a
    where a.household_id = p_household_id and a.request_id = p_request_id
      and a.attempt_kind in ('initial', 'reproposal') and a.state = 'accepted'
  ) or v_request.linked_task_instance_id is null then
    raise exception 'REQUEST_AGREEMENT_NOT_ESTABLISHED';
  end if;

  select * into v_task from public.task_instances t
  where t.household_id = p_household_id and t.id = v_request.linked_task_instance_id
  for share;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if v_task.test_context_id is distinct from p_test_context_id then
    raise exception 'ACTOR_SCOPE_CONFLICT';
  end if;
  if v_task.revision <> p_expected_task_revision then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  if v_task.status not in ('todo', 'in_progress') then raise exception 'TASK_NOT_OPEN'; end if;

  v_terms := jsonb_build_object(
    'target_task_revision', p_expected_task_revision,
    'reason', nullif(btrim(coalesce(p_reason, '')), '')
  );
  if p_attempt_kind = 'change' then
    v_terms := v_terms || jsonb_build_object('task_patch', coalesce(p_task_patch, '{}'::jsonb));
  end if;
  perform private.fn_validate_post_accept_request_terms_v1(
    p_household_id, p_test_context_id, p_attempt_kind, v_terms
  );

  insert into public.request_attempts (
    household_id, request_id, attempt_kind, state, terms_revision, terms,
    reply_due_at, created_by_actor_ref_id, test_context_id
  ) values (
    p_household_id, p_request_id, p_attempt_kind, 'awaiting_confirmation', 1,
    v_terms, p_reply_due_at, p_actor_ref_id, p_test_context_id
  ) returning id into v_attempt_id;

  insert into public.request_attempt_confirmations (
    household_id, attempt_id, terms_revision, actor_ref_id, test_context_id
  ) values (
    p_household_id, v_attempt_id, 1, p_actor_ref_id, p_test_context_id
  );

  perform private.fn_project_request_legacy_lifecycle_v1(p_household_id, p_request_id);
  select revision into v_request_revision
  from public.requests where household_id = p_household_id and id = p_request_id;

  v_other_actor_ref := case when v_request.requester_actor_ref_id = p_actor_ref_id
    then v_request.recipient_actor_ref_id else v_request.requester_actor_ref_id end;
  perform private.fn_emit_notification_intent_v1(
    p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
    v_other_actor_ref, 'request.followup_requested',
    case when p_attempt_kind = 'cancel' then 'お願いの取消確認' else 'お願いの変更確認' end,
    v_request.shared_title,
    jsonb_build_object('request_id', p_request_id, 'attempt_id', v_attempt_id,
      'attempt_kind', p_attempt_kind, 'terms_revision', 1),
    'request:followup:' || v_attempt_id::text,
    'immediate', 'normal', 'request:' || p_request_id::text,
    p_reply_due_at, 'request', p_request_id, v_request_revision
  );

  v_result := jsonb_build_object(
    'request_id', p_request_id, 'attempt_id', v_attempt_id,
    'attempt_kind', p_attempt_kind, 'state', 'awaiting_confirmation',
    'revision', 1, 'terms_revision', 1,
    'request_revision', v_request_revision
  );
  perform private.fn_complete_canonical_operation_v1(
    v_receipt_id, 'request', p_request_id, v_result
  );
  return v_result;
end;
$$;
revoke all on function private.fn_command_start_request_followup_v1(
  uuid, uuid, uuid, uuid, uuid, text, jsonb, text, timestamptz,
  bigint, bigint, uuid, text
) from public, anon, authenticated;
grant execute on function private.fn_command_start_request_followup_v1(
  uuid, uuid, uuid, uuid, uuid, text, jsonb, text, timestamptz,
  bigint, bigint, uuid, text
) to service_role;

create or replace function private.fn_command_decline_request_followup_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_request_id uuid,
  p_attempt_id uuid,
  p_expected_revision bigint,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_request public.requests%rowtype;
  v_attempt public.request_attempts%rowtype;
  v_revision bigint;
  v_result jsonb;
begin
  if p_source not in ('line', 'pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
    p_operation_id, 'request.followup.decline',
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'request_id', p_request_id, 'attempt_id', p_attempt_id,
      'expected_revision', p_expected_revision, 'source', p_source
    ))
  );
  if v_claim->>'disposition' = 'replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_request from public.requests r
  where r.household_id = p_household_id and r.id = p_request_id for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.test_context_id is distinct from p_test_context_id then
    raise exception 'ACTOR_SCOPE_CONFLICT';
  end if;
  perform private.fn_request_party_role_v1(v_request, p_actor_ref_id);

  select * into v_attempt from public.request_attempts a
  where a.household_id = p_household_id and a.id = p_attempt_id
    and a.request_id = p_request_id for update;
  if not found then raise exception 'REQUEST_ATTEMPT_NOT_FOUND'; end if;
  if v_attempt.test_context_id is distinct from p_test_context_id then
    raise exception 'ACTOR_SCOPE_CONFLICT';
  end if;
  if v_attempt.attempt_kind not in ('change', 'cancel')
     or v_attempt.state not in ('consulting', 'awaiting_confirmation') then
    raise exception 'REQUEST_TRANSITION_INVALID';
  end if;
  if v_attempt.created_by_actor_ref_id = p_actor_ref_id then
    raise exception 'REQUEST_TRANSITION_INVALID';
  end if;
  if v_attempt.revision <> p_expected_revision then
    raise exception 'REQUEST_ATTEMPT_STALE';
  end if;

  update public.request_attempts
  set state = 'declined', declined_at = now(), revision = revision + 1
  where id = p_attempt_id returning revision into v_revision;
  perform private.fn_project_request_legacy_lifecycle_v1(p_household_id, p_request_id);

  perform private.fn_emit_notification_intent_v1(
    p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
    v_attempt.created_by_actor_ref_id, 'request.followup_declined',
    '変更提案は成立しませんでした', v_request.shared_title,
    jsonb_build_object('request_id', p_request_id, 'attempt_id', p_attempt_id,
      'attempt_kind', v_attempt.attempt_kind, 'state', 'declined'),
    'request:followup-declined:' || p_attempt_id::text || ':' || v_revision::text,
    'immediate', 'normal', 'request:' || p_request_id::text,
    v_attempt.reply_due_at, 'request', p_request_id, v_revision
  );

  v_result := jsonb_build_object(
    'request_id', p_request_id, 'attempt_id', p_attempt_id,
    'state', 'declined', 'revision', v_revision
  );
  perform private.fn_complete_canonical_operation_v1(
    v_receipt_id, 'request', p_request_id, v_result
  );
  return v_result;
end;
$$;
revoke all on function private.fn_command_decline_request_followup_v1(
  uuid,uuid,uuid,uuid,uuid,uuid,bigint,uuid,text
) from public, anon, authenticated;
grant execute on function private.fn_command_decline_request_followup_v1(
  uuid,uuid,uuid,uuid,uuid,uuid,bigint,uuid,text
) to service_role;

-- Keep recipient-owned LINE action rows unique on replay. Their operation IDs
-- are deterministic derivatives, so this index also closes concurrent adapter
-- replay without creating a second button for one Request/action.
create unique index pending_actions_request_response_once_v2
  on private.pending_actions (
    actor_id, action_type, ((normalized_payload->>'request_id'))
  )
  where action_type in ('request_accept', 'request_decline')
    and normalized_payload ? 'request_id';

create or replace function private.fn_refresh_queued_request_outbox_payload_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.type <> 'request.received' or new.payload is not distinct from old.payload then
    return new;
  end if;

  update private.notification_outbox o
  set payload = jsonb_set(
    o.payload,
    '{items}',
    coalesce((
      select jsonb_agg(
        case when item->>'user_notification_id' = new.id::text
          then item || jsonb_build_object('payload', new.payload)
          else item end
      )
      from jsonb_array_elements(coalesce(o.payload->'items', '[]'::jsonb)) item
    ), '[]'::jsonb),
    true
  )
  where o.recipient_user_id = new.recipient_user_id
    and o.status = 'queued'
    and o.test_context_id is null
    and exists (
      select 1 from jsonb_array_elements(coalesce(o.payload->'items', '[]'::jsonb)) item
      where item->>'user_notification_id' = new.id::text
    );
  return new;
end;
$$;
revoke all on function private.fn_refresh_queued_request_outbox_payload_v1()
  from public, anon, authenticated;
grant execute on function private.fn_refresh_queued_request_outbox_payload_v1()
  to service_role;
create trigger user_notifications_refresh_request_outbox_payload_v1
  after update of payload on public.user_notifications
  for each row execute function private.fn_refresh_queued_request_outbox_payload_v1();

create or replace function public.server_tx_send_request(
  p_actor_id uuid,
  p_operation_id uuid,
  p_recipient_user_id uuid,
  p_shared_title text,
  p_shared_message text,
  p_due_at timestamptz
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_recipient_actor_ref_id uuid;
  v_result jsonb;
  v_request_id uuid;
  v_accept_action_id uuid;
  v_decline_action_id uuid;
  v_expiry timestamptz;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;
  v_actor_ref_id := (v_context->>'actor_ref_id')::uuid;

  select a.id into v_recipient_actor_ref_id
  from public.domain_actor_refs a
  where a.household_id = v_household_id and a.actor_kind = 'real_user'
    and a.real_user_id = p_recipient_user_id;
  if v_recipient_actor_ref_id is null or p_recipient_user_id = p_actor_id then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  v_result := private.fn_command_create_light_request_v1(
    v_household_id, p_actor_id, v_actor_ref_id, null,
    v_recipient_actor_ref_id, p_shared_title, p_shared_message, p_due_at,
    p_operation_id, 'pwa'
  );
  v_request_id := (v_result->>'request_id')::uuid;
  v_expiry := greatest(
    now() + interval '24 hours',
    coalesce(p_due_at + interval '6 hours', now() + interval '24 hours')
  );

  insert into private.pending_actions (
    household_id, actor_id, source, action_type, normalized_payload,
    operation_id, status, expires_at, actor_ref_id, test_context_id
  ) values (
    v_household_id, p_recipient_user_id, 'line', 'request_accept',
    jsonb_build_object('request_id', v_request_id),
    md5(p_operation_id::text || ':canonical-request-accept')::uuid,
    'draft', v_expiry, v_recipient_actor_ref_id, null
  ) on conflict do nothing;
  select id into v_accept_action_id from private.pending_actions
  where actor_id = p_recipient_user_id and action_type = 'request_accept'
    and normalized_payload->>'request_id' = v_request_id::text;

  insert into private.pending_actions (
    household_id, actor_id, source, action_type, normalized_payload,
    operation_id, status, expires_at, actor_ref_id, test_context_id
  ) values (
    v_household_id, p_recipient_user_id, 'line', 'request_decline',
    jsonb_build_object('request_id', v_request_id),
    md5(p_operation_id::text || ':canonical-request-decline')::uuid,
    'draft', v_expiry, v_recipient_actor_ref_id, null
  ) on conflict do nothing;
  select id into v_decline_action_id from private.pending_actions
  where actor_id = p_recipient_user_id and action_type = 'request_decline'
    and normalized_payload->>'request_id' = v_request_id::text;

  update public.user_notifications
  set payload = payload || jsonb_build_object(
    'request_kind', 'general',
    'due_at', p_due_at,
    'accept_pending_action_id', v_accept_action_id,
    'decline_pending_action_id', v_decline_action_id
  )
  where recipient_user_id = p_recipient_user_id
    and dedup_key = 'request:received:' || v_request_id::text;

  return v_result;
end;
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

create or replace function public.server_tx_start_request_followup(
  p_actor_id uuid,
  p_operation_id uuid,
  p_request_id uuid,
  p_attempt_kind text,
  p_task_patch jsonb,
  p_reason text,
  p_reply_due_at timestamptz,
  p_expected_request_revision bigint,
  p_expected_task_revision bigint
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare v_context jsonb;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  return private.fn_command_start_request_followup_v1(
    (v_context->>'household_id')::uuid, p_actor_id,
    (v_context->>'actor_ref_id')::uuid, null, p_request_id,
    p_attempt_kind, p_task_patch, p_reason, p_reply_due_at,
    p_expected_request_revision, p_expected_task_revision,
    p_operation_id, 'pwa'
  );
end;
$$;

revoke all on function public.server_tx_send_request(uuid,uuid,uuid,text,text,timestamptz)
  from public, anon, authenticated;
revoke all on function public.server_tx_accept_request(uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.server_tx_decline_request(uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.server_tx_cancel_request(uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.server_tx_start_request_followup(
  uuid,uuid,uuid,text,jsonb,text,timestamptz,bigint,bigint
) from public, anon, authenticated;
grant execute on function public.server_tx_send_request(uuid,uuid,uuid,text,text,timestamptz)
  to service_role;
grant execute on function public.server_tx_accept_request(uuid,uuid,uuid)
  to service_role;
grant execute on function public.server_tx_decline_request(uuid,uuid,uuid)
  to service_role;
grant execute on function public.server_tx_cancel_request(uuid,uuid,uuid)
  to service_role;
grant execute on function public.server_tx_start_request_followup(
  uuid,uuid,uuid,text,jsonb,text,timestamptz,bigint,bigint
) to service_role;

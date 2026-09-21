-- Physical F2 UX hardening (2026-09-21)
-- The recipient's first "引き受ける" tap moves the canonical attempt to
-- checking so the second/final confirmation is CAS-protected.
--
-- Product behavior:
-- 1) requester gets one useful status update: recipient showed intent to accept;
-- 2) assignment is NOT changed until explicit final confirmation;
-- 3) if checking remains open for 10 minutes, recipient gets one reminder;
-- 4) no time-based auto-accept.
CREATE OR REPLACE FUNCTION private.fn_command_transition_request_attempt_v1(p_household_id uuid, p_operator_user_id uuid, p_actor_ref_id uuid, p_test_context_id uuid, p_request_id uuid, p_attempt_id uuid, p_action text, p_terms jsonb, p_expected_revision bigint, p_expected_terms_revision integer, p_operation_id uuid, p_source text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    update public.request_attempts set state = v_new_state, revision = revision + 1
    where id = v_attempt.id returning revision into v_new_revision;

  elsif p_action = 'consult' then
    if v_attempt.state not in ('pending', 'checking') then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    v_new_state := 'consulting';
    update public.request_attempts set state = v_new_state, revision = revision + 1
    where id = v_attempt.id returning revision into v_new_revision;

  elsif p_action = 'edit_terms' then
    if v_attempt.state not in ('consulting', 'awaiting_confirmation') then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    if p_terms is null or p_terms = '{}'::jsonb then raise exception 'REQUEST_TERMS_REQUIRED'; end if;
    if v_request.request_kind='assignment_change' then
      if p_terms->'assignment_targets' is distinct from v_attempt.terms->'assignment_targets'
        or p_terms->'due_at' is distinct from v_attempt.terms->'due_at' then
        raise exception 'REQUEST_ASSIGNMENT_REPROPOSAL_REQUIRED';
      end if;
    end if;
    v_new_terms_revision := v_attempt.terms_revision + 1;
    v_new_state := 'consulting';
    update public.request_attempts
    set terms = p_terms,
        terms_revision = v_new_terms_revision,
        state = v_new_state,
        revision = revision + 1
    where id = v_attempt.id returning revision into v_new_revision;

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
    -- The first recipient tap is meaningful: tell the requester that the
    -- recipient expressed intent to accept, but make the remaining explicit
    -- confirmation equally clear. This is status, not assignment truth.
    perform private.fn_emit_notification_intent_v1(
      p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
      v_request.requester_actor_ref_id,
      'request.checking',
      '引き受ける意向あり',
      '相手が「引き受ける」を押しました。最終確認待ちです。未確定ならこちらから確認を促します。',
      jsonb_build_object(
        'request_id', p_request_id,
        'attempt_id', p_attempt_id,
        'state', v_new_state,
        'followup', 'recipient_final_confirmation'
      ),
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
$function$;



-- One reminder after 10 minutes if the recipient expressed intent but did not
-- complete the explicit final confirmation. The reminder is idempotent per
-- checking revision and never accepts on the recipient's behalf.
create or replace function public.server_tx_dispatch_request_checking_reminders_v1(
  p_now_utc timestamptz default now(),
  p_row_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_row record;
  v_count integer := 0;
begin
  if p_now_utc is null or p_row_limit < 1 then
    raise exception 'INVALID_INPUT';
  end if;

  for v_row in
    select
      a.household_id,
      a.id as attempt_id,
      a.revision as attempt_revision,
      a.reply_due_at,
      r.id as request_id,
      r.shared_title,
      r.due_at,
      r.requester_actor_ref_id,
      r.recipient_actor_ref_id,
      requester.real_user_id as requester_user_id
    from public.request_attempts a
    join public.requests r
      on r.household_id = a.household_id
     and r.id = a.request_id
    join public.domain_actor_refs requester
      on requester.household_id = r.household_id
     and requester.id = r.requester_actor_ref_id
    where a.test_context_id is null
      and r.test_context_id is null
      and r.request_kind = 'assignment_change'
      and a.state = 'checking'
      and a.updated_at <= p_now_utc - interval '10 minutes'
      and (a.reply_due_at is null or a.reply_due_at > p_now_utc)
      and requester.actor_kind = 'real_user'
      and requester.real_user_id is not null
    order by a.updated_at, a.id
    limit p_row_limit
    for update of a skip locked
  loop
    perform private.fn_emit_notification_intent_v1(
      v_row.household_id,
      v_row.requester_user_id,
      v_row.requester_actor_ref_id,
      null,
      v_row.recipient_actor_ref_id,
      'request.checking',
      '最終確認が残っています',
      '「' || coalesce(v_row.shared_title, 'お願い') || '」はまだ確定していません。引き受ける場合はトークの「確定（引受）」を押してください。',
      jsonb_build_object(
        'request_id', v_row.request_id,
        'attempt_id', v_row.attempt_id,
        'state', 'checking',
        'reminder', 'final_confirmation'
      ),
      'request:checking-reminder:' || v_row.attempt_id::text || ':' || v_row.attempt_revision::text,
      'immediate',
      'normal',
      'request:' || v_row.request_id::text,
      coalesce(v_row.reply_due_at, v_row.due_at),
      'request',
      v_row.request_id,
      v_row.attempt_revision
    );
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('reminders_considered', v_count);
end;
$function$;

revoke all on function public.server_tx_dispatch_request_checking_reminders_v1(timestamptz, integer)
  from public, anon, authenticated;
grant execute on function public.server_tx_dispatch_request_checking_reminders_v1(timestamptz, integer)
  to service_role;

-- Fold checking follow-up into the existing once-per-minute Family Ops worker.
create or replace function public.server_tx_dispatch_family_ops_automation_v2(
  p_now_utc timestamptz default now(),
  p_row_limit integer default 2000
)
returns jsonb
language plpgsql
set search_path = ''
as $function$
declare
  v_daily jsonb;
  v_codmon jsonb;
  v_request_followup jsonb;
  v_legacy jsonb;
  v_p1 boolean;
begin
  v_daily:=public.server_tx_dispatch_daily_briefs(p_now_utc);
  v_codmon:=public.server_tx_dispatch_codmon_reminders_v1(p_now_utc);
  v_request_followup:=public.server_tx_dispatch_request_checking_reminders_v1(p_now_utc, least(p_row_limit, 200));

  select release_stage='P1' into v_p1
  from private.canonical_capability_gates
  where capability='daily_brief_v2';

  if coalesce(v_p1,false) then
    v_legacy:=jsonb_build_object('suppressed',true,'reason','DAILY_BRIEF_P1');
  else
    v_legacy:=public.server_tx_dispatch_routine_automation(p_now_utc,p_row_limit);
  end if;

  return jsonb_build_object(
    'daily_brief',v_daily,
    'codmon',v_codmon,
    'request_followup',v_request_followup,
    'legacy',v_legacy
  );
end;
$function$;

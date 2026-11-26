-- Explicit assignment acceptance and ordinary reply deferral both enter
-- checking, but only explicit assignment acceptance needs a final reminder.
alter table public.request_attempts
  add column checking_intent text check (checking_intent = 'assignment_accept');

create or replace function private.fn_line_preference_column_for_type(p_type text)
returns text language sql immutable security invoker set search_path = '' as $$
  select case when p_type in (
    'assignment.consent_change_requested', 'request.consulting', 'request.awaiting_confirmation'
  ) then 'request_line'
  else private.fn_line_preference_before_assignment_consent_v1(p_type) end;
$$;

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
  v_target_actor_ref_id uuid;
  v_notification_payload jsonb;
  v_shared_terms jsonb;
begin
  if p_action not in ('checking', 'begin_assignment_accept', 'consult', 'edit_terms', 'confirm_terms', 'accept', 'decline', 'cancel') then
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

  elsif p_action = 'begin_assignment_accept' then
    if v_party <> 'recipient' or v_request.request_kind <> 'assignment_change'
      or v_attempt.state not in ('pending', 'checking') or v_attempt.checking_intent is not null then
      raise exception 'REQUEST_TRANSITION_INVALID';
    end if;
    v_new_state := 'checking';
    update public.request_attempts
    set state = v_new_state, checking_intent = 'assignment_accept', revision = revision + 1
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

    if not found then
      -- A fresh operation ID can confirm an already-confirmed terms version.
      -- Keep the same attempt revision and receipt without another delivery.
      v_result := jsonb_build_object(
        'request_id', p_request_id, 'attempt_id', p_attempt_id,
        'state', v_attempt.state, 'revision', v_attempt.revision,
        'terms_revision', v_attempt.terms_revision, 'linked_task_id', null
      );
      perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'request', p_request_id, v_result);
      return v_result;
    end if;

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

  v_target_actor_ref_id := case when v_party = 'recipient'
    then v_request.requester_actor_ref_id else v_request.recipient_actor_ref_id end;
  v_notification_payload := jsonb_strip_nulls(jsonb_build_object(
    'request_id', p_request_id, 'attempt_id', p_attempt_id,
    'state', v_new_state, 'revision', v_new_revision, 'terms_revision', v_new_terms_revision,
    'request_kind', v_request.request_kind, 'shared_title', v_request.shared_title,
    'shared_message', v_request.shared_message
  ));

  if p_action in ('checking', 'begin_assignment_accept') then
    perform private.fn_emit_notification_intent_v1(
      p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
      v_target_actor_ref_id, 'request.checking',
      case when p_action = 'begin_assignment_accept' then '引き受ける意向あり' else '相手が確認中です' end,
      case when p_action = 'begin_assignment_accept'
        then '相手が「引き受ける」を押しました。相手の最終確認を待っています。'
        else '相手が返事を保留しました。返事を待っています。' end,
      v_notification_payload || case when p_action = 'begin_assignment_accept'
        then jsonb_build_object('followup', 'recipient_final_confirmation') else '{}'::jsonb end,
      'request:checking:' || p_attempt_id::text || ':' || v_new_revision::text,
      'immediate', 'normal', 'request:' || p_request_id::text,
      v_request.due_at, 'request', p_request_id, v_new_revision
    );
  elsif p_action in ('consult', 'edit_terms') or v_new_state = 'awaiting_confirmation' then
    v_shared_terms := case when p_action = 'edit_terms' then p_terms else v_attempt.terms end;

    -- Publish only the shared memo and validated work deadline. Other terms
    -- can contain internal identifiers, draft text, or arbitrary client keys.
    v_notification_payload := v_notification_payload || jsonb_strip_nulls(jsonb_build_object(
      'consultation_event', case p_action when 'consult' then 'started' when 'edit_terms' then 'updated' end,
      'candidate', case when jsonb_typeof(v_shared_terms->'candidate') = 'string'
        then nullif(btrim(v_shared_terms->>'candidate'), '') end,
      'proposed_due_at', case when v_attempt.attempt_kind in ('initial', 'reproposal')
        then v_shared_terms#>>'{material_patch,work_due_at}' end
    ));

    perform private.fn_emit_notification_intent_v1(
      p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
      v_target_actor_ref_id, 'request.' || v_new_state,
      case p_action when 'consult' then '相手が相談を始めました'
        when 'edit_terms' then '相手が相談の内容を更新しました'
        else '相手がこの条件を確認しました' end,
      '「' || v_request.shared_title || '」の相談内容を開いて、条件を確認してください。'
        || case when p_action = 'confirm_terms'
          then 'あなたが同じ内容を確認すると確定します。'
          else '二人が同じ内容を確認すると確定します。' end,
      v_notification_payload,
      'request:' || p_action || ':' || p_attempt_id::text || ':' || v_new_terms_revision::text,
      'immediate', 'normal', 'request:' || p_request_id::text,
      v_attempt.reply_due_at, 'request', p_request_id, v_new_revision
    );
  elsif v_new_state in ('accepted', 'declined', 'cancelled') then
    perform private.fn_emit_notification_intent_v1(
      p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
      v_target_actor_ref_id, 'request.' || v_new_state,
      case when p_action = 'confirm_terms' then '二人が同じ条件を確認しました' else 'お願いを更新しました' end,
      v_request.shared_title,
      v_notification_payload || jsonb_strip_nulls(jsonb_build_object(
        'task_id', v_task_id, 'confirmation_mode', case when p_action = 'confirm_terms' then 'mutual' end
      )),
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
      a.terms_revision,
      a.reply_due_at,
      r.id as request_id,
      r.shared_title,
      r.shared_message,
      r.request_kind,
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
      and a.checking_intent = 'assignment_accept'
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
      '「' || coalesce(v_row.shared_title, 'お願い') || '」はまだ確定していません。お願いを開いて、引き受ける場合は最終確認してください。',
      jsonb_build_object(
        'request_id', v_row.request_id,
        'attempt_id', v_row.attempt_id,
        'state', 'checking',
        'revision', v_row.attempt_revision,
        'terms_revision', v_row.terms_revision,
        'request_kind', v_row.request_kind,
        'shared_title', v_row.shared_title,
        'shared_message', v_row.shared_message,
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

-- Include the shared title and message when any canonical request is sent.
-- Both fields come from the recipient-scoped request, never from a draft.
create function private.fn_add_received_request_shared_context_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_shared_context jsonb;
begin
  select jsonb_strip_nulls(jsonb_build_object(
    'shared_title', r.shared_title,
    'shared_message', r.shared_message
  )) into v_shared_context
  from public.requests r
  where r.id = new.aggregate_id
    and r.household_id = new.household_id
    and r.recipient_actor_ref_id = new.recipient_actor_ref_id
    and r.recipient_id = new.recipient_user_id
    and r.test_context_id is null;

  if found then
    new.payload := coalesce(new.payload, '{}'::jsonb) || v_shared_context;
  end if;
  return new;
end;
$$;

revoke all on function private.fn_add_received_request_shared_context_v1()
  from public, anon, authenticated;
grant execute on function private.fn_add_received_request_shared_context_v1() to service_role;

create trigger user_notifications_add_received_request_shared_context_v1
  before insert on public.user_notifications
  for each row
  when (new.notification_kind = 'request.received' and new.aggregate_type = 'request'
    and new.test_context_id is null)
  execute function private.fn_add_received_request_shared_context_v1();

-- The legacy type alias can be set in the same update that attaches the
-- recipient's actions. Keep the queued canonical item in sync with the row.
create or replace function private.fn_refresh_queued_request_outbox_payload_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.type not in ('request.received', 'request_received')
    or new.test_context_id is not null
    or new.payload is not distinct from old.payload then
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
        order by position
      )
      from jsonb_array_elements(coalesce(o.payload->'items', '[]'::jsonb))
        with ordinality as items(item, position)
    ), '[]'::jsonb),
    true
  )
  where o.household_id = new.household_id
    and o.recipient_user_id = new.recipient_user_id
    and o.channel = 'line'
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

-- Ensure every unresolved request/negotiation is visible in scheduled Daily Briefs.
-- Covers assigned-task handoff requests as well as unassigned-task negotiations.
CREATE OR REPLACE FUNCTION public.server_read_daily_brief_pre_codmon_readiness_v1(p_actor_id uuid, p_local_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_date date:=coalesce(p_local_date,(now() at time zone 'Asia/Tokyo')::date);
  v_brief jsonb;
  v_anyone jsonb:='[]'::jsonb;
  v_urgent jsonb:='[]'::jsonb;
  v_groups jsonb;
  v_request_waiting jsonb:='[]'::jsonb;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;
  select hm.household_id into v_household_id
  from public.household_members hm
  where hm.user_id=p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select id into v_actor_ref_id
  from public.domain_actor_refs
  where household_id=v_household_id
    and actor_kind='real_user'
    and real_user_id=p_actor_id
    and test_context_id is null;

  v_brief:=public.server_read_daily_brief_pre_assignment_action_v1(
    p_actor_id,p_local_date
  );

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',t.id,
    'title',t.title||'（誰でもOK）',
    'status',t.status,
    'task_kind',t.task_kind,
    'category',t.category,
    'routine_phase',t.routine_phase,
    'scheduled_date',t.scheduled_date,
    'due_at',t.due_at,
    'planned_assignee_id',null,
    'planned_assignee_actor_ref_id',null,
    'assignment_mode','anyone',
    'active_claimant_actor_ref_id',t.active_claimant_actor_ref_id,
    'claimed_at',t.claimed_at,
    'completion_mode',t.completion_mode,
    'expectation',coalesce(t.expectation,'normal'),
    'duplicate_sensitivity',coalesce(t.duplicate_sensitivity,'normal'),
    'revision',t.revision,
    'action_target',jsonb_build_object('kind','task','task_id',t.id,'revision',t.revision)
  ) order by t.due_at nulls last,t.title),'[]'::jsonb)
  into v_anyone
  from public.task_instances t
  where t.household_id=v_household_id
    and t.test_context_id is null
    and t.scheduled_date=v_date
    and t.status in ('todo','in_progress')
    and t.attention_state='active'
    and t.assignment_mode='anyone'
    and (
      t.active_claimant_actor_ref_id is null
      or t.active_claimant_actor_ref_id is distinct from v_actor_ref_id
    );

  if jsonb_array_length(v_anyone)>0 then
    v_brief:=v_brief||jsonb_build_object(
      'tasks',coalesce(v_brief->'tasks','[]'::jsonb)||v_anyone
    );

    select jsonb_build_object(
      'morning',coalesce(v_brief#>'{own_task_groups,morning}','[]'::jsonb)
        ||coalesce(jsonb_agg(item order by item->>'due_at',item->>'title')
          filter(where item->>'routine_phase'='morning'
            and coalesce(item->>'expectation','normal')<>'optional'),'[]'::jsonb),
      'daytime',coalesce(v_brief#>'{own_task_groups,daytime}','[]'::jsonb)
        ||coalesce(jsonb_agg(item order by item->>'due_at',item->>'title')
          filter(where coalesce(item->>'routine_phase','') not in ('morning','evening')
            and coalesce(item->>'expectation','normal')<>'optional'),'[]'::jsonb),
      'evening',coalesce(v_brief#>'{own_task_groups,evening}','[]'::jsonb)
        ||coalesce(jsonb_agg(item order by item->>'due_at',item->>'title')
          filter(where item->>'routine_phase'='evening'
            and coalesce(item->>'expectation','normal')<>'optional'),'[]'::jsonb),
      'optional',coalesce(v_brief#>'{own_task_groups,optional}','[]'::jsonb)
        ||coalesce(jsonb_agg(item order by item->>'due_at',item->>'title')
          filter(where coalesce(item->>'expectation','normal')='optional'),'[]'::jsonb)
    )
    into v_groups
    from jsonb_array_elements(v_anyone) item;

    v_brief:=v_brief||jsonb_build_object(
      'own_task_groups',v_groups,
      'sections',coalesce(v_brief->'sections','{}'::jsonb)
        ||jsonb_build_object('own_task_groups',v_groups)
    );
  end if;

  -- anyone is already a valid assignment mode: never present it as
  -- "担当未定 / 先に決めること".
  select coalesce(jsonb_agg(item order by ord),'[]'::jsonb)
  into v_urgent
  from jsonb_array_elements(coalesce(v_brief->'urgent_actions','[]'::jsonb))
    with ordinality as entries(item,ord)
  left join public.task_instances t
    on item->>'kind'='assignment_needed'
   and nullif(item->>'task_id','') is not null
   and t.household_id=v_household_id
   and t.id=(item->>'task_id')::uuid
  where not (
    item->>'kind'='assignment_needed'
    and coalesce(t.assignment_mode,'unassigned')='anyone'
  );

  -- Preserve assignment-request negotiation enrichment from the prior wrapper.
  select coalesce(jsonb_agg(
    case when pending.request_id is not null then
      item
      ||jsonb_build_object(
        'kind','assignment_negotiation',
        'title',coalesce(nullif(item->>'title',''),'担当未定')
          ||' → '||pending.recipient_label||'にお願い中',
        'state',pending.state,
        'request_id',pending.request_id,
        'attempt_id',pending.attempt_id,
        'reply_due_at',pending.reply_due_at
      )
    else item end
    order by ord
  ),'[]'::jsonb)
  into v_urgent
  from jsonb_array_elements(v_urgent) with ordinality as entries(item,ord)
  left join lateral (
    select r.id as request_id,a.id as attempt_id,a.state,a.reply_due_at,
      case hm.family_role when 'mama' then 'ママ' when 'papa' then 'パパ' else '相手' end as recipient_label
    from public.requests r
    join lateral (
      select x.id,x.state,x.reply_due_at
      from public.request_attempts x
      where x.household_id=r.household_id
        and x.request_id=r.id
        and x.test_context_id is null
        and x.state in ('pending','checking','consulting','awaiting_confirmation')
      order by x.created_at desc,x.id desc
      limit 1
    ) a on true
    left join public.household_members hm
      on hm.household_id=r.household_id and hm.user_id=r.recipient_id
    where item->>'kind'='assignment_needed'
      and nullif(item->>'task_id','') is not null
      and r.household_id=v_household_id
      and r.test_context_id is null
      and r.request_kind='assignment_change'
      and r.assignment_task_instance_id=(item->>'task_id')::uuid
    order by r.created_at desc,r.id desc
    limit 1
  ) pending on true;

  -- Only an explicit first-stage acceptance has a final confirmation.
  select coalesce(jsonb_agg(
    case
      when item->>'state'='checking' and exists (
        select 1 from public.request_attempts a
        where a.household_id=v_household_id
          and a.id=(item->>'attempt_id')::uuid
          and a.test_context_id is null
          and a.checking_intent='assignment_accept'
      ) then
        (item - 'state' - 'title')
        || jsonb_build_object(
          'title','お願い「'||coalesce(nullif(item->>'title',''),'お願い')||'」：最終確認待ち（確定（引受））'
        )
      else item
    end
    order by ord
  ),'[]'::jsonb)
  into v_urgent
  from jsonb_array_elements(v_urgent) with ordinality as entries(item,ord);

  -- Unresolved Requests must remain visible in every scheduled Daily Brief,
  -- even when the underlying task already has an assignee. The previous
  -- assignment-negotiation enrichment only covered assignment_needed rows,
  -- which missed the common "Papa担当 -> Mamaへ変更依頼" case.
  select coalesce(jsonb_agg(jsonb_build_object(
    'kind','request_followup',
    'request_id',r.id,
    'attempt_id',a.id,
    'state',a.state,
    'reply_due_at',a.reply_due_at,
    'title',
      case
        when r.requester_id=p_actor_id and a.state='pending'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：返事待ち'
        when r.requester_id=p_actor_id and a.state='checking' and a.checking_intent='assignment_accept'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：相手が引き受ける意向・最終確認待ち'
        when r.requester_id=p_actor_id and a.state='checking'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：相手の返事待ち'
        when r.requester_id=p_actor_id and a.state='consulting'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：相談中'
        when r.requester_id=p_actor_id and a.state='awaiting_confirmation'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：条件の確認待ち'
        when r.recipient_id=p_actor_id and a.state='pending'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：返事が必要'
        when r.recipient_id=p_actor_id and a.state='checking' and a.checking_intent='assignment_accept'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：最終確認待ち（確定（引受））'
        when r.recipient_id=p_actor_id and a.state='checking'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：返事が必要'
        when r.recipient_id=p_actor_id and a.state='consulting'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：相談中'
        else 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：条件の確認待ち'
      end
  ) order by coalesce(a.reply_due_at,r.due_at) nulls last,r.created_at),'[]'::jsonb)
  into v_request_waiting
  from public.requests r
  join lateral (
    select x.id,x.state,x.reply_due_at,x.created_at,x.checking_intent
    from public.request_attempts x
    where x.household_id=r.household_id
      and x.request_id=r.id
      and x.test_context_id is null
      and x.state in ('pending','checking','consulting','awaiting_confirmation')
    order by x.created_at desc,x.id desc
    limit 1
  ) a on true
  where r.household_id=v_household_id
    and r.test_context_id is null
    and (r.requester_id=p_actor_id or r.recipient_id=p_actor_id)
    and not exists (
      select 1
      from jsonb_array_elements(v_urgent) u
      where u->>'request_id'=r.id::text
    );

  return v_brief||jsonb_build_object(
    'urgent_actions',v_urgent,
    'waiting_checks',coalesce(v_brief->'waiting_checks','[]'::jsonb)||v_request_waiting,
    'sections',coalesce(v_brief->'sections','{}'::jsonb)
      ||jsonb_build_object(
        'confirm_first',v_urgent,
        'waiting_checks',coalesce(v_brief->'waiting_checks','[]'::jsonb)||v_request_waiting
      )
  );
end;
$function$


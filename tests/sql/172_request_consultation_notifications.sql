\set ON_ERROR_STOP on
begin;
set role service_role;

do $$
declare
  requester uuid := gen_random_uuid();
  recipient uuid := gen_random_uuid();
  outsider uuid := gen_random_uuid();
  household uuid;
  created jsonb;
  result jsonb;
  replay jsonb;
  request_id uuid;
  attempt_id uuid;
  operation_id uuid;
  terms jsonb;
  shared_due timestamptz := now() + interval '3 days';
  notification_payload jsonb;
begin
  insert into auth.users (id) values (requester), (recipient), (outsider);
  household := (public.server_tx_create_household(
    requester, gen_random_uuid(), 'Consultation household', 'Requester'
  )->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (household, recipient, 'adult');
  perform public.server_tx_create_household(outsider, gen_random_uuid(), 'Outside household', 'Outsider');
  perform private.backfill_canonical_foundation_v1();

  insert into public.notification_preferences (household_id, user_id, request_line)
  values (household, requester, true), (household, recipient, true)
  on conflict (household_id, user_id) do update set request_line = true;

  insert into private.line_user_links (household_id, user_id, line_user_id)
  values (household, requester, 'consult-' || requester::text),
         (household, recipient, 'consult-' || recipient::text);

  created := public.server_tx_send_request_v2(
    requester, gen_random_uuid(), recipient, 'お迎え', '正面玄関へお願いします',
    now() + interval '2 days', now() + interval '1 day'
  );
  request_id := (created->>'request_id')::uuid;
  attempt_id := (created->>'attempt_id')::uuid;

  -- The compatibility alias is set after insert; both channels need the
  -- same public snapshot and the receiver's current action IDs.
  select n.payload into strict notification_payload from public.user_notifications n
  where n.aggregate_id = request_id and n.recipient_user_id = recipient
    and n.type = 'request_received' and n.notification_kind = 'request.received';
  if notification_payload->>'shared_title' is distinct from 'お迎え'
    or notification_payload->>'shared_message' is distinct from '正面玄関へお願いします'
    or notification_payload->>'accept_pending_action_id' is null or notification_payload->>'decline_pending_action_id' is null
    or not exists (
      select 1 from private.notification_outbox o
      where o.recipient_user_id = recipient and o.status = 'queued'
        and o.type = 'request.received' and o.payload#>'{items,0,payload}' = notification_payload
    ) then
    raise exception 'FAIL shared request context or queued alias action data';
  end if;

  begin
    perform public.server_tx_transition_request_v2(outsider, gen_random_uuid(),
      request_id, attempt_id, 'consult', null, 1, 1, 'pwa');
    raise exception 'FAIL outside household started consultation';
  exception when others then
    if sqlerrm <> 'REQUEST_NOT_FOUND' then raise; end if;
  end;

  operation_id := gen_random_uuid();
  result := public.server_tx_transition_request_v2(recipient, operation_id,
    request_id, attempt_id, 'consult', null, 1, 1, 'line');
  replay := public.server_tx_transition_request_v2(recipient, operation_id,
    request_id, attempt_id, 'consult', null, 1, 1, 'line');
  if result is distinct from replay or result->>'state' is distinct from 'consulting' then
    raise exception 'FAIL consultation receipt replay';
  end if;
  if (select count(*) from public.user_notifications n where n.aggregate_id = request_id
      and n.type = 'request.consulting') <> 1 or not exists (
    select 1 from public.user_notifications n
    join private.notification_outbox o on o.household_id = n.household_id
      and o.recipient_user_id = n.recipient_user_id
      and o.payload#>>'{items,0,user_notification_id}' = n.id::text
    where n.aggregate_id = request_id and n.recipient_user_id = requester
      and n.type = 'request.consulting' and n.payload->>'consultation_event' = 'started'
      and n.payload->>'attempt_id' = attempt_id::text and n.payload->>'terms_revision' = '1'
      and o.type = 'request.consulting' and o.payload#>'{items,0,payload}' = n.payload
  ) then
    raise exception 'FAIL consultation start partner-only delivery';
  end if;

  update public.notification_preferences set request_line = false
  where household_id = household and user_id = recipient;
  select a.terms into terms from public.request_attempts a where a.id = attempt_id;
  terms := terms || jsonb_build_object('candidate', '18時半なら行けます',
    'raw_text', 'PRIVATE-ONLY-TEXT', 'draft_id', 'PRIVATE-ONLY-ID',
    'material_patch', jsonb_build_object('version', 1, 'work_due_at', shared_due));

  operation_id := gen_random_uuid();
  result := public.server_tx_transition_request_v2(requester, operation_id,
    request_id, attempt_id, 'edit_terms', terms, 2, 1, 'pwa');
  replay := public.server_tx_transition_request_v2(requester, operation_id,
    request_id, attempt_id, 'edit_terms', terms, 2, 1, 'pwa');
  if result is distinct from replay or result->>'terms_revision' is distinct from '2' then
    raise exception 'FAIL edit receipt replay';
  end if;
  select n.payload into strict notification_payload from public.user_notifications n
  where n.aggregate_id = request_id and n.recipient_user_id = recipient
    and n.type = 'request.consulting' and n.payload->>'consultation_event' = 'updated';
  if notification_payload->>'candidate' is distinct from '18時半なら行けます'
    or (notification_payload->>'proposed_due_at')::timestamptz is distinct from shared_due
    or notification_payload::text like '%PRIVATE-ONLY%' or notification_payload ? 'material_patch'
    or exists (
      select 1 from private.notification_outbox o
      where o.recipient_user_id = recipient and o.type = 'request.consulting'
        and o.payload#>>'{items,0,payload,request_id}' = request_id::text
    ) then
    raise exception 'FAIL private draft or disabled LINE preference boundary';
  end if;

  operation_id := gen_random_uuid();
  result := public.server_tx_transition_request_v2(recipient, operation_id,
    request_id, attempt_id, 'confirm_terms', null, 3, 2, 'line');
  replay := public.server_tx_transition_request_v2(recipient, operation_id,
    request_id, attempt_id, 'confirm_terms', null, 3, 2, 'line');
  if result is distinct from replay or result->>'state' is distinct from 'awaiting_confirmation' then
    raise exception 'FAIL first confirmation receipt replay';
  end if;
  replay := public.server_tx_transition_request_v2(recipient, gen_random_uuid(),
    request_id, attempt_id, 'confirm_terms', null, 4, 2, 'pwa');
  if result is distinct from replay or exists (
    select 1 from public.user_notifications n where n.aggregate_id = request_id and n.type = 'request.accepted'
  ) then
    raise exception 'FAIL repeated same-party confirmation changed state or confirmed';
  end if;
  if (select count(*) from public.user_notifications n where n.aggregate_id = request_id
    and n.type = 'request.awaiting_confirmation') <> 1 or not exists (
    select 1 from public.user_notifications n
    join private.notification_outbox o on o.household_id = n.household_id
      and o.recipient_user_id = n.recipient_user_id
      and o.payload#>>'{items,0,user_notification_id}' = n.id::text
    where n.aggregate_id = request_id and n.recipient_user_id = requester
      and n.type = 'request.awaiting_confirmation' and n.payload->>'terms_revision' = '2'
      and n.payload->>'candidate' = '18時半なら行けます'
      and n.payload::text not like '%PRIVATE-ONLY%'
      and o.type = n.type and o.payload#>'{items,0,payload}' = n.payload
  ) then
    raise exception 'FAIL one first confirmation to other person';
  end if;

  -- A new version requires two fresh confirmations, in either actor order.
  update public.notification_preferences set request_line = true
  where household_id = household and user_id = recipient;
  terms := terms || jsonb_build_object('candidate', '19時なら行けます');
  perform public.server_tx_transition_request_v2(requester, gen_random_uuid(),
    request_id, attempt_id, 'edit_terms', terms, 4, 2, 'pwa');
  if not exists (
    select 1 from private.notification_outbox o
    where o.recipient_user_id = recipient and o.type = 'request.consulting'
      and o.payload#>>'{items,0,payload,request_id}' = request_id::text
      and o.payload#>>'{items,0,payload,candidate}' = '19時なら行けます'
  ) then
    raise exception 'FAIL update delivery with LINE enabled';
  end if;
  begin
    perform public.server_tx_transition_request_v2(requester, gen_random_uuid(),
      request_id, attempt_id, 'confirm_terms', null, 5, 2, 'pwa');
    raise exception 'FAIL confirmed old terms';
  exception when others then
    if sqlerrm <> 'REQUEST_TERMS_REVISION_STALE' then raise; end if;
  end;
  result := public.server_tx_transition_request_v2(requester, gen_random_uuid(),
    request_id, attempt_id, 'confirm_terms', null, 5, 3, 'pwa');
  if result->>'state' is distinct from 'awaiting_confirmation' or not exists (
    select 1 from public.user_notifications n
    where n.aggregate_id = request_id and n.recipient_user_id = recipient
      and n.type = 'request.awaiting_confirmation' and n.payload->>'terms_revision' = '3'
  ) then
    raise exception 'FAIL first confirmation on new terms version';
  end if;

  operation_id := gen_random_uuid();
  result := public.server_tx_transition_request_v2(recipient, operation_id,
    request_id, attempt_id, 'confirm_terms', null, 6, 3, 'line');
  perform public.server_tx_transition_request_v2(recipient, operation_id,
    request_id, attempt_id, 'confirm_terms', null, 6, 3, 'line');
  if result->>'state' is distinct from 'accepted' or (select count(*)
    from public.user_notifications n where n.aggregate_id = request_id and n.type = 'request.accepted'
    and n.recipient_user_id = requester and n.payload->>'confirmation_mode' = 'mutual') <> 1 then
    raise exception 'FAIL second confirmation or deduplication';
  end if;
end;
$$;

do $$
declare
  requester uuid := gen_random_uuid();
  recipient uuid := gen_random_uuid();
  household uuid;
  requester_ref uuid;
  task_id uuid;
  created jsonb;
  request_id uuid;
  attempt_id uuid;
  operation_id uuid;
  result jsonb;
begin
  insert into auth.users (id) values (requester), (recipient);
  household := (public.server_tx_create_household(
    requester, gen_random_uuid(), 'Checking household', 'Requester'
  )->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (household, recipient, 'adult');
  perform private.backfill_canonical_foundation_v1();
  select a.id into requester_ref
  from public.domain_actor_refs a where a.household_id = household and a.real_user_id = requester;

  insert into public.task_instances(
    household_id, origin, title, category, routine_phase, scheduled_date, planned_assignee_id,
    completion_mode, status, source, created_by, assignment_mode, assignment_source,
    planned_assignee_actor_ref_id, due_at
  ) values (
    household, 'manual', 'お迎え', 'pickup', 'evening', current_date, requester,
    'whole', 'todo', 'test', requester, 'person', 'manual', requester_ref, now() + interval '2 days'
  ) returning id into task_id;
  created := public.server_tx_create_assignment_change_request(
    requester, gen_random_uuid(), task_id, recipient, '担当変更をお願いします', 'once'
  );
  request_id := (created->>'request_id')::uuid;
  attempt_id := (created->>'attempt_id')::uuid;

  perform public.server_tx_transition_request_v2(recipient, gen_random_uuid(),
    request_id, attempt_id, 'checking', null, 1, 1, 'line');
  perform public.server_tx_dispatch_request_checking_reminders_v1(now() + interval '11 minutes', 100);
  if (select count(*) from public.user_notifications n where n.aggregate_id = request_id
    and n.type = 'request.checking') <> 1 or not exists (
    select 1 from public.user_notifications n where n.aggregate_id = request_id
    and n.recipient_user_id = requester and n.type = 'request.checking' and not (n.payload ? 'followup')
  ) or public.server_read_daily_brief(requester, current_date)::text like '%引き受ける意向%'
    or public.server_read_daily_brief(recipient, current_date)::text like '%最終確認待ち%' then
    raise exception 'FAIL ordinary checking incorrectly signals intent to accept';
  end if;

  operation_id := gen_random_uuid();
  result := public.server_tx_transition_request_v2(recipient, operation_id,
    request_id, attempt_id, 'begin_assignment_accept', null, 2, 1, 'line');
  perform public.server_tx_transition_request_v2(recipient, operation_id,
    request_id, attempt_id, 'begin_assignment_accept', null, 2, 1, 'line');
  perform public.server_tx_dispatch_request_checking_reminders_v1(now() + interval '11 minutes', 100);
  perform public.server_tx_dispatch_request_checking_reminders_v1(now() + interval '12 minutes', 100);
  if result->>'revision' is distinct from '3' or (select count(*)
    from public.user_notifications n where n.aggregate_id = request_id and n.type = 'request.checking'
      and n.recipient_user_id = requester and n.payload->>'followup' = 'recipient_final_confirmation') <> 1
    or (select count(*) from public.user_notifications n where n.aggregate_id = request_id
      and n.type = 'request.checking' and n.recipient_user_id = recipient
      and n.payload->>'reminder' = 'final_confirmation' and n.payload->>'revision' = '3') <> 1
    or (select t.planned_assignee_id from public.task_instances t where t.id = task_id) is distinct from requester then
    raise exception 'FAIL explicit assignment intent or recipient reminder';
  end if;
end;
$$;

do $$
declare
  operator uuid := gen_random_uuid();
  household uuid;
  context_id uuid;
  simulated_ref uuid;
  operator_ref uuid;
  created jsonb;
  request_id uuid;
  attempt_id uuid;
begin
  insert into auth.users (id) values (operator);
  household := (public.server_tx_create_household(
    operator, gen_random_uuid(), 'Simulation household', 'Operator'
  )->>'household_id')::uuid;
  update private.canonical_capability_gates
  set release_stage = 'P1', reader_enabled = true, writer_enabled = true,
      mutation_paused = false, p1_crossed_at = now(), updated_at = now()
  where capability = 'one_user_simulation_v1';
  context_id := (public.server_tx_open_test_simulation_interactive_v1(
    operator, gen_random_uuid(), 'mama', 'Consultation check'
  )->>'test_context_id')::uuid;
  select a.id into strict simulated_ref from public.domain_actor_refs a
  where a.household_id = household and a.test_context_id = context_id and a.actor_kind = 'simulated_member';

  created := public.server_tx_test_simulation_send_request_v1(
    operator, context_id, gen_random_uuid(), 'simulated_to_operator',
    'テストのお迎え', '検証用メッセージ', now() + interval '2 days'
  );
  request_id := (created->>'request_id')::uuid;
  attempt_id := (created->>'attempt_id')::uuid;
  select r.recipient_actor_ref_id into strict operator_ref from public.requests r where r.id = request_id;
  perform private.fn_command_transition_request_attempt_v1(household, operator, operator_ref, context_id,
    request_id, attempt_id, 'consult', null, 1, 1, gen_random_uuid(), 'pwa');
  if not exists (
    select 1 from private.test_delivery_outbox d
    where d.test_context_id = context_id and d.semantic_actor_ref_id = simulated_ref
      and d.rendered_payload->>'notification_kind' = 'request.consulting'
      and d.rendered_payload#>>'{payload,request_id}' = request_id::text
  ) or exists (
    select 1 from public.user_notifications n where n.household_id = household
  ) or exists (
    select 1 from private.notification_outbox o where o.household_id = household
  ) then
    raise exception 'FAIL consultation notification escaped simulation';
  end if;
end;
$$;

rollback;

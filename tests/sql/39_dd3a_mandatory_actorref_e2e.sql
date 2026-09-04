-- Mandatory ActorRef / one-operator test-sandbox E2E from canonical design §13.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_operator uuid := gen_random_uuid();
  v_partner uuid := gen_random_uuid();
  v_hh jsonb;
  v_household uuid;
  v_context uuid;
  v_papa uuid;
  v_mama uuid;
  v_result jsonb;
  v_request uuid;
  v_attempt uuid;
  v_task uuid;
  v_revision bigint;
  v_any_task uuid;
  v_consult_request uuid;
  v_consult_attempt uuid;
  v_consult_task uuid;
  v_terms jsonb := jsonb_build_object('when', 'tomorrow', 'note', 'same exact terms');
  v_prod_notifications bigint;
  v_prod_notification_outbox bigint;
  v_google_mirrors bigint;
  v_google_writes bigint;
begin
  insert into auth.users (id) values (v_operator), (v_partner);
  v_hh := public.server_tx_create_household(
    v_operator, gen_random_uuid(), 'DD3A mandatory E2E ' || v_operator::text, 'Owner'
  );
  v_household := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_household, v_partner, 'adult');

  perform private.backfill_canonical_foundation_v1();
  select id into v_papa
  from public.domain_actor_refs
  where household_id = v_household and actor_kind = 'real_user' and real_user_id = v_operator;

  insert into public.test_simulation_contexts (household_id, operator_user_id, label)
  values (v_household, v_operator, 'mandatory-e2e') returning id into v_context;
  insert into public.domain_actor_refs (household_id, actor_kind, test_context_id, simulated_role)
  values (v_household, 'simulated_member', v_context, 'mama') returning id into v_mama;

  if private.fn_actor_display_label_v1(v_household, v_mama) <> '🧪 ママ' then
    raise exception 'FAIL mandatory e2e: simulated mama display identity is not explicit';
  end if;

  select count(*) into v_prod_notifications from public.user_notifications;
  select count(*) into v_prod_notification_outbox from private.notification_outbox;
  select count(*) into v_google_mirrors from private.family_ops_calendar_mirrors;
  select count(*) into v_google_writes from private.google_write_operations;

  -- 1. Papa/operator creates a test Request to simulated mama.
  v_result := private.fn_command_create_light_request_v1(
    v_household, v_operator, v_papa, v_context, v_mama,
    '保育園バッグを確認', 'テスト依頼', now() + interval '4 hours',
    gen_random_uuid(), 'pwa'
  );
  v_request := (v_result->>'request_id')::uuid;
  v_attempt := (v_result->>'attempt_id')::uuid;

  if not exists (
    select 1 from public.requests r
    where r.id = v_request
      and r.requester_id = v_operator
      and r.requester_actor_ref_id = v_papa
      and r.recipient_id is null
      and r.recipient_actor_ref_id = v_mama
      and r.test_context_id = v_context
  ) then
    raise exception 'FAIL mandatory e2e: simulated request recipient was substituted by operator';
  end if;

  -- 2. Simulated mama enters checking. Legacy compatibility remains pending.
  perform private.fn_command_transition_request_attempt_v1(
    v_household, v_operator, v_mama, v_context,
    v_request, v_attempt, 'checking', null, 1, 1, gen_random_uuid(), 'line'
  );
  if (select status from public.requests where id = v_request) <> 'pending'
     or (select state from public.request_attempts where id = v_attempt) <> 'checking' then
    raise exception 'FAIL mandatory e2e: checking state/projection mismatch';
  end if;

  -- 3-4. Simulated mama accepts; the linked task is assigned to mama ActorRef
  -- while the legacy real-user assignee remains NULL.
  v_result := private.fn_command_transition_request_attempt_v1(
    v_household, v_operator, v_mama, v_context,
    v_request, v_attempt, 'accept', null, 2, 1, gen_random_uuid(), 'line'
  );
  v_task := (v_result->>'linked_task_id')::uuid;
  if v_task is null or not exists (
    select 1 from public.task_instances t
    where t.id = v_task
      and t.planned_assignee_actor_ref_id = v_mama
      and t.planned_assignee_id is null
      and t.assignment_mode = 'person'
      and t.assignment_source = 'agreement'
      and t.test_context_id = v_context
  ) then
    raise exception 'FAIL mandatory e2e: linked test task did not preserve simulated assignee';
  end if;

  -- 5. Simulated mama claims an anyone task.
  insert into public.task_instances (
    household_id, origin, title, category, routine_phase, scheduled_date,
    completion_mode, status, source, created_by, assignment_mode,
    assignment_source, test_context_id
  ) values (
    v_household, 'manual', '誰でもOKテスト', 'other', 'anytime',
    (now() at time zone 'Asia/Tokyo')::date,
    'whole', 'todo', 'dd3a_e2e', v_operator, 'anyone', 'manual', v_context
  ) returning id into v_any_task;
  perform private.fn_command_task_claim_v1(
    v_household, v_operator, v_mama, v_context, v_any_task,
    'claim', null, null, 1, gen_random_uuid(), 'pwa'
  );
  if (select active_claimant_actor_ref_id from public.task_instances where id = v_any_task) <> v_mama then
    raise exception 'FAIL mandatory e2e: simulated mama could not become claimant';
  end if;

  -- 6. Simulated mama completes and is performer + recorder; no legacy user ID.
  select revision into v_revision from public.task_instances where id = v_task;
  perform private.fn_command_complete_task_v1(
    v_household, v_operator, v_mama, v_context, v_task,
    array[v_mama]::uuid[], v_revision, gen_random_uuid(), 'line'
  );
  if not exists (
    select 1 from public.task_actual_participants p
    where p.task_instance_id = v_task
      and p.actor_ref_id = v_mama
      and p.recorded_by_actor_ref_id = v_mama
      and p.test_context_id = v_context
      and p.removed_at is null
  ) then
    raise exception 'FAIL mandatory e2e: performer/recorder ActorRef evidence missing';
  end if;
  if (select actual_completed_by_id from public.task_instances where id = v_task) is not null then
    raise exception 'FAIL mandatory e2e: operator leaked into legacy actual performer';
  end if;
  if not exists (
    select 1 from public.task_events e
    where e.task_instance_id = v_task
      and e.event_type = 'completed'
      and e.actor_id is null
      and e.actor_ref_id = v_mama
      and private.fn_actor_display_label_v1(e.household_id, e.actor_ref_id) = '🧪 ママ'
  ) then
    raise exception 'FAIL mandatory e2e: audit actor is not semantic test mama';
  end if;

  -- 7. Consultation confirms exact terms once as real papa ActorRef and once as
  -- simulated mama ActorRef. Authentication operator remains the same user.
  v_result := private.fn_command_create_light_request_v1(
    v_household, v_operator, v_papa, v_context, v_mama,
    '相談テスト', null, now() + interval '1 day', gen_random_uuid(), 'pwa'
  );
  v_consult_request := (v_result->>'request_id')::uuid;
  v_consult_attempt := (v_result->>'attempt_id')::uuid;

  perform private.fn_command_transition_request_attempt_v1(
    v_household, v_operator, v_papa, v_context,
    v_consult_request, v_consult_attempt, 'consult', null,
    1, 1, gen_random_uuid(), 'pwa'
  );
  perform private.fn_command_transition_request_attempt_v1(
    v_household, v_operator, v_papa, v_context,
    v_consult_request, v_consult_attempt, 'edit_terms', v_terms,
    2, 1, gen_random_uuid(), 'pwa'
  );

  if not exists (
    select 1 from public.request_attempt_confirmations c
    where c.attempt_id = v_consult_attempt
      and c.terms_revision = 2
      and c.actor_ref_id = v_papa
      and c.test_context_id = v_context
  ) then
    raise exception 'FAIL mandatory e2e: proposer papa confirmation missing';
  end if;

  v_result := private.fn_command_transition_request_attempt_v1(
    v_household, v_operator, v_mama, v_context,
    v_consult_request, v_consult_attempt, 'confirm_terms', null,
    3, 2, gen_random_uuid(), 'line'
  );
  v_consult_task := (v_result->>'linked_task_id')::uuid;

  if (select count(*) from public.request_attempt_confirmations c
      where c.attempt_id = v_consult_attempt and c.terms_revision = 2
        and c.actor_ref_id in (v_papa, v_mama)) <> 2 then
    raise exception 'FAIL mandatory e2e: exact terms revision does not have both domain ActorRef confirmations';
  end if;
  if (select state from public.request_attempts where id = v_consult_attempt) <> 'accepted'
     or v_consult_task is null then
    raise exception 'FAIL mandatory e2e: both confirmations did not establish agreement once';
  end if;

  -- 8. Test delivery and semantic labels say 🧪 mama; they never say the real
  -- operator performed mama's actions.
  if not exists (
    select 1 from private.test_delivery_outbox d
    where d.test_context_id = v_context
      and d.operator_user_id = v_operator
      and d.semantic_actor_ref_id = v_mama
      and d.rendered_payload->>'text' like '🧪 テスト: ママへの通知%'
  ) then
    raise exception 'FAIL mandatory e2e: synthetic mama delivery/provenance missing';
  end if;

  -- 9. Production LINE/in-app/Google mutation paths remain untouched.
  if (select count(*) from public.user_notifications) <> v_prod_notifications then
    raise exception 'FAIL mandatory e2e: test flow wrote production user_notifications';
  end if;
  if (select count(*) from private.notification_outbox) <> v_prod_notification_outbox then
    raise exception 'FAIL mandatory e2e: test flow wrote production notification_outbox';
  end if;
  if (select count(*) from private.family_ops_calendar_mirrors) <> v_google_mirrors then
    raise exception 'FAIL mandatory e2e: test flow wrote production Google mirror';
  end if;
  if (select count(*) from private.google_write_operations) <> v_google_writes then
    raise exception 'FAIL mandatory e2e: test flow wrote production Google write operation';
  end if;
end;
$$;

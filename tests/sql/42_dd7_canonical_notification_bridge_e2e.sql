-- WP-DD7 canonical notification intent -> existing LINE outbox E2E.
\set ON_ERROR_STOP on

set role service_role;
do $$
declare
  v_papa uuid := gen_random_uuid();
  v_mama uuid := gen_random_uuid();
  v_hh jsonb;
  v_hh_id uuid;
  v_papa_actor uuid;
  v_mama_actor uuid;
  v_req jsonb;
  v_task_normal uuid := gen_random_uuid();
  v_task_duplicate uuid := gen_random_uuid();
  v_before_notifications bigint;
  v_test_context uuid;
  v_sim_papa uuid;
  v_sim_mama uuid;
  v_test_req jsonb;
begin
  insert into auth.users (id) values (v_papa), (v_mama);
  v_hh := public.server_tx_create_household(
    v_papa, gen_random_uuid(), 'DD7 notification HH ' || v_papa::text, 'Papa'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, v_mama, 'adult');

  insert into public.notification_preferences (
    household_id, user_id, request_line, routine_completion_line
  ) values
    (v_hh_id, v_papa, true, true),
    (v_hh_id, v_mama, true, true)
  on conflict (household_id, user_id) do update
    set request_line = true, routine_completion_line = true;

  insert into private.line_user_links (household_id, user_id, line_user_id)
  values
    (v_hh_id, v_papa, 'U-dd7-papa-' || replace(v_papa::text, '-', '')),
    (v_hh_id, v_mama, 'U-dd7-mama-' || replace(v_mama::text, '-', ''));

  perform private.backfill_canonical_foundation_v1();
  select id into v_papa_actor from public.domain_actor_refs
  where household_id = v_hh_id and actor_kind = 'real_user' and real_user_id = v_papa;
  select id into v_mama_actor from public.domain_actor_refs
  where household_id = v_hh_id and actor_kind = 'real_user' and real_user_id = v_mama;

  -- Existing unrelated queued work must not absorb a new action-required
  -- canonical Request intent.
  insert into private.notification_outbox (
    household_id, recipient_user_id, channel, type, payload, dedup_key, priority,
    business_expires_at
  ) values (
    v_hh_id, v_mama, 'line', 'legacy_unrelated',
    jsonb_build_object('items', '[]'::jsonb),
    'dd7-existing-unrelated-' || gen_random_uuid()::text,
    'normal', now() + interval '1 day'
  );

  v_req := private.fn_command_create_light_request_v1(
    v_hh_id, v_papa, v_papa_actor, null, v_mama_actor,
    '急ぎのお願い', '今日中に確認してください', now() + interval '2 hours',
    gen_random_uuid(), 'pwa'
  );

  if not exists (
    select 1 from public.user_notifications
    where household_id = v_hh_id and recipient_user_id = v_mama
      and type = 'request.received' and urgency = 'immediate'
  ) then
    raise exception 'FAIL dd7-notification: canonical request intent missing';
  end if;
  if not exists (
    select 1 from private.notification_outbox
    where household_id = v_hh_id and recipient_user_id = v_mama
      and type = 'request.received'
      and dedup_key like 'canonical:request:received:%'
      and status = 'queued'
  ) then
    raise exception 'FAIL dd7-notification: urgent request not bridged independently';
  end if;
  if (select count(*) from private.notification_outbox
      where household_id = v_hh_id and recipient_user_id = v_mama and status = 'queued') < 2 then
    raise exception 'FAIL dd7-notification: urgent request was incorrectly folded into unrelated bundle';
  end if;

  -- Normal completion mutates shared state and actuals but produces no immediate
  -- semantic notification intent.
  insert into public.task_instances (
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    planned_assignee_id, completion_mode, status, source, created_by,
    assignment_mode, assignment_source, planned_assignee_actor_ref_id,
    duplicate_sensitivity, revision
  ) values (
    v_task_normal, v_hh_id, 'manual', '普通の家事', 'other', 'anytime', current_date,
    v_mama, 'whole', 'todo', 'test', v_papa,
    'person', 'manual', v_mama_actor, 'normal', 1
  );

  select count(*) into v_before_notifications
  from public.user_notifications where household_id = v_hh_id;

  perform private.fn_command_complete_task_v1(
    v_hh_id, v_papa, v_papa_actor, null,
    v_task_normal, array[v_papa_actor], 1, gen_random_uuid(), 'pwa'
  );

  if (select count(*) from public.user_notifications where household_id = v_hh_id)
      <> v_before_notifications then
    raise exception 'FAIL dd7-notification: normal completion created proactive notification';
  end if;

  -- Duplicate-sensitive completion creates an actor-neutral immediate intent and
  -- the existing outbox receives it without changing sender/quota semantics.
  insert into public.task_instances (
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    planned_assignee_id, completion_mode, status, source, created_by,
    assignment_mode, assignment_source, planned_assignee_actor_ref_id,
    duplicate_sensitivity, revision
  ) values (
    v_task_duplicate, v_hh_id, 'manual', '朝の薬', 'health', 'morning', current_date,
    v_mama, 'whole', 'todo', 'test', v_papa,
    'person', 'manual', v_mama_actor, 'avoid_duplicate', 1
  );

  perform private.fn_command_complete_task_v1(
    v_hh_id, v_papa, v_papa_actor, null,
    v_task_duplicate, array[v_papa_actor], 1, gen_random_uuid(), 'pwa'
  );

  if not exists (
    select 1 from public.user_notifications
    where household_id = v_hh_id and recipient_user_id = v_mama
      and type = 'task.completed_neutral'
      and title = '対応済み'
      and body = '朝の薬は対応済みです'
      and urgency = 'immediate'
  ) then
    raise exception 'FAIL dd7-notification: duplicate-sensitive neutral intent missing';
  end if;
  if not exists (
    select 1 from private.notification_outbox
    where household_id = v_hh_id and recipient_user_id = v_mama
      and type = 'task.completed_neutral'
      and status = 'queued'
  ) then
    raise exception 'FAIL dd7-notification: duplicate-sensitive intent not bridged';
  end if;

  -- Test simulation must never create production notification or LINE outbox
  -- work. It is delivered only through the dedicated synthetic outbox.
  insert into public.test_simulation_contexts (household_id, operator_user_id, label)
  values (v_hh_id, v_papa, 'dd7-isolation') returning id into v_test_context;
  insert into public.domain_actor_refs (
    household_id, actor_kind, test_context_id, simulated_role
  ) values
    (v_hh_id, 'simulated_member', v_test_context, 'papa') returning id into v_sim_papa;
  insert into public.domain_actor_refs (
    household_id, actor_kind, test_context_id, simulated_role
  ) values
    (v_hh_id, 'simulated_member', v_test_context, 'mama') returning id into v_sim_mama;

  select count(*) into v_before_notifications
  from public.user_notifications where household_id = v_hh_id;

  v_test_req := private.fn_command_create_light_request_v1(
    v_hh_id, v_papa, v_sim_papa, v_test_context, v_sim_mama,
    'テストお願い', 'productionには出さない', now() + interval '1 hour',
    gen_random_uuid(), 'pwa'
  );

  if (select count(*) from public.user_notifications where household_id = v_hh_id)
      <> v_before_notifications then
    raise exception 'FAIL dd7-notification: test simulation leaked into user_notifications';
  end if;
  if not exists (
    select 1 from private.test_delivery_outbox
    where household_id = v_hh_id and test_context_id = v_test_context
      and semantic_actor_ref_id = v_sim_mama
      and rendered_payload->>'notification_kind' = 'request.received'
  ) then
    raise exception 'FAIL dd7-notification: synthetic test delivery missing';
  end if;
  if exists (
    select 1 from private.notification_outbox
    where household_id = v_hh_id and test_context_id is not null
  ) then
    raise exception 'FAIL dd7-notification: test simulation leaked into production LINE outbox';
  end if;
end;
$$;

reset role;
select 'dd7_canonical_notification_bridge_e2e: PASS' as result;

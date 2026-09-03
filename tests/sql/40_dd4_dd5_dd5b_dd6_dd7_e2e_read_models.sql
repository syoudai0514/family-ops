-- WP-DD4..DD7 downstream R0/read-policy E2E invariants.
\set ON_ERROR_STOP on

set role service_role;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_partner uuid := gen_random_uuid();
  v_hh jsonb;
  v_hh_id uuid;
  v_owner_actor uuid;
  v_partner_actor uuid;
  v_test_context uuid;
  v_task uuid := gen_random_uuid();
  v_req uuid := gen_random_uuid();
  v_accepted_attempt uuid := gen_random_uuid();
  v_change_attempt uuid := gen_random_uuid();
  v_test_req uuid := gen_random_uuid();
  v_shop uuid;
  v_request_workspace jsonb;
  v_task_history jsonb;
  v_shop_workspace jsonb;
  v_slots jsonb;
  v_claim jsonb;
  v_prod_outbox uuid := gen_random_uuid();
  v_test_outbox uuid := gen_random_uuid();
  v_inapp_outbox uuid := gen_random_uuid();
begin
  insert into auth.users (id) values (v_owner), (v_partner);

  v_hh := public.server_tx_create_household(
    v_owner, gen_random_uuid(), 'DD4-DD7 E2E HH', 'Owner'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;

  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, v_partner, 'adult');

  insert into public.domain_actor_refs (household_id, actor_kind, real_user_id)
  values (v_hh_id, 'real_user', v_owner)
  returning id into v_owner_actor;

  insert into public.domain_actor_refs (household_id, actor_kind, real_user_id)
  values (v_hh_id, 'real_user', v_partner)
  returning id into v_partner_actor;

  -- DD4: accepted agreement is durable while a later change negotiation is
  -- pending; execution truth belongs to the linked Task and may already be
  -- complete without collapsing the Request coordination state.
  insert into public.task_instances (
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    due_at, completion_mode, status, actual_completed_by_id, completed_at,
    source, created_by, assignment_mode, planned_assignee_actor_ref_id,
    expectation, carryover_policy, duplicate_sensitivity
  ) values (
    v_task, v_hh_id, 'manual', '保育園の提出', 'submission', 'anytime', date '2030-01-02',
    timestamptz '2030-01-02 08:00+09', 'whole', 'completed', v_partner,
    timestamptz '2030-01-02 07:50+09', 'pwa', v_owner,
    'person', v_partner_actor, 'required', 'occurrence_ends', 'avoid_duplicate'
  );

  insert into public.task_actual_participants (
    household_id, task_instance_id, actor_ref_id, recorded_by_actor_ref_id
  ) values
    (v_hh_id, v_task, v_owner_actor, v_owner_actor),
    (v_hh_id, v_task, v_partner_actor, v_owner_actor);

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, shared_message,
    due_at, status, linked_task_instance_id, accepted_at,
    requester_actor_ref_id, recipient_actor_ref_id, request_kind
  ) values (
    v_req, v_hh_id, v_owner, v_partner, '提出お願い', '朝までにお願い',
    timestamptz '2030-01-02 08:00+09', 'accepted', v_task,
    timestamptz '2030-01-01 20:00+09', v_owner_actor, v_partner_actor, 'light'
  );

  insert into public.request_attempts (
    id, household_id, request_id, attempt_kind, state, terms_revision, terms,
    created_by_actor_ref_id, accepted_at, revision, created_at
  ) values (
    v_accepted_attempt, v_hh_id, v_req, 'initial', 'accepted', 1,
    jsonb_build_object('summary', '朝までに提出'), v_owner_actor,
    timestamptz '2030-01-01 20:00+09', 1, timestamptz '2030-01-01 19:55+09'
  );

  insert into public.request_attempts (
    id, household_id, request_id, attempt_kind, state, terms_revision, terms,
    reply_due_at, created_by_actor_ref_id, revision, created_at
  ) values (
    v_change_attempt, v_hh_id, v_req, 'change', 'pending', 2,
    jsonb_build_object('summary', '提出場所を変更'),
    timestamptz '2030-01-02 07:30+09', v_partner_actor, 1,
    timestamptz '2030-01-02 07:00+09'
  );

  v_request_workspace := public.server_read_request_workspace(v_partner);
  if not exists (
    select 1 from jsonb_array_elements(v_request_workspace->'incoming') e
    where e->>'request_id' = v_req::text
      and (e->>'agreement_established')::boolean
      and e->>'coordination_state' = 'agreement_with_negotiation'
      and e->'current_attempt'->>'attempt_id' = v_change_attempt::text
      and e->'current_attempt'->>'attempt_kind' = 'change'
      and e->'current_attempt'->>'state' = 'pending'
      and e->'execution'->>'task_id' = v_task::text
      and e->'execution'->>'status' = 'completed'
  ) then
    raise exception 'FAIL DD4: agreement/change negotiation/execution were collapsed: %', v_request_workspace;
  end if;

  -- Direct test Request must never appear in production request workspace.
  insert into public.test_simulation_contexts (household_id, operator_user_id, label)
  values (v_hh_id, v_owner, 'DD4-DD7 sandbox')
  returning id into v_test_context;

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status,
    requester_actor_ref_id, recipient_actor_ref_id, request_kind, test_context_id
  ) values (
    v_test_req, v_hh_id, v_owner, v_partner, 'sandbox request', 'pending',
    v_owner_actor, v_partner_actor, 'light', v_test_context
  );

  if exists (
    select 1 from jsonb_array_elements(public.server_read_request_workspace(v_partner)->'incoming') e
    where e->>'request_id' = v_test_req::text
  ) then
    raise exception 'FAIL DD4: test Request leaked into production workspace';
  end if;

  -- DD5: two performers remain two evidence rows but one household completion.
  v_task_history := public.server_read_task_result_history(v_owner, date '2030-01-01');
  if not exists (
    select 1 from jsonb_array_elements(v_task_history->'items') e
    where e->>'task_id' = v_task::text
      and e->>'semantic_result' = 'completed'
      and (e->>'performer_count')::int = 2
      and (e->>'household_completion_units')::int = 1
      and jsonb_array_length(e->'performers') = 2
  ) then
    raise exception 'FAIL DD5: multi-performer task was double-counted or lost: %', v_task_history;
  end if;

  -- Explicit negative outcomes are facts, while open old work remains unknown.
  insert into public.task_instances (
    household_id, origin, title, category, routine_phase, scheduled_date,
    completion_mode, status, source, created_by, assignment_mode,
    outcome_reason, attention_state
  ) values
    (v_hh_id, 'manual', '今回は不要', 'other', 'anytime', date '2030-01-01',
      'whole', 'skipped', 'pwa', v_owner, 'unassigned', 'not_needed_this_occurrence', 'active'),
    (v_hh_id, 'manual', 'できなかった', 'other', 'anytime', date '2030-01-01',
      'whole', 'skipped', 'pwa', v_owner, 'unassigned', 'could_not_do', 'active'),
    (v_hh_id, 'manual', '結果不明', 'other', 'anytime', date '2030-01-01',
      'whole', 'todo', 'pwa', v_owner, 'unassigned', null, 'active'),
    (v_hh_id, 'manual', '待ち', 'other', 'anytime', date '2030-01-01',
      'whole', 'todo', 'pwa', v_owner, 'unassigned', null, 'waiting');

  v_task_history := public.server_read_task_result_history(v_owner, date '2030-01-01');
  if not exists (select 1 from jsonb_array_elements(v_task_history->'items') e where e->>'title'='今回は不要' and e->>'semantic_result'='not_needed')
     or not exists (select 1 from jsonb_array_elements(v_task_history->'items') e where e->>'title'='できなかった' and e->>'semantic_result'='could_not_do')
     or not exists (select 1 from jsonb_array_elements(v_task_history->'items') e where e->>'title'='結果不明' and e->>'semantic_result'='open_or_unknown' and e->>'result_certainty'='unknown')
     or not exists (select 1 from jsonb_array_elements(v_task_history->'items') e where e->>'title'='待ち' and e->>'semantic_result'='waiting') then
    raise exception 'FAIL DD5: result/waiting semantics were conflated: %', v_task_history;
  end if;

  -- DD5B: Shopping actual evidence preserves both performers, but the purchased
  -- item contributes one household completion unit.
  v_shop := (public.server_tx_add_shopping_item(
    v_owner, gen_random_uuid(), '牛乳', 'store', null, null, null
  )->>'shopping_item_id')::uuid;
  update public.shopping_items
  set status = 'purchased', purchased_at = now(), duplicate_sensitivity = 'avoid_duplicate'
  where id = v_shop;

  insert into public.shopping_actual_participants (
    household_id, shopping_item_id, actor_ref_id, recorded_by_actor_ref_id
  ) values
    (v_hh_id, v_shop, v_owner_actor, v_owner_actor),
    (v_hh_id, v_shop, v_partner_actor, v_owner_actor);

  v_shop_workspace := public.server_read_shopping_workspace(v_owner);
  if not exists (
    select 1 from jsonb_array_elements(v_shop_workspace->'history') e
    where e->>'shopping_item_id' = v_shop::text
      and (e->>'performer_count')::int = 2
      and jsonb_array_length(e->'performers') = 2
      and (e->>'household_completion_units')::int = 1
  ) then
    raise exception 'FAIL DD5B: shopping actual evidence lost/double-counted: %', v_shop_workspace;
  end if;

  -- DD6: exact base cadence and one-date override. 2030-01-02 is Wednesday.
  insert into public.household_routine_schedules
    (household_id, schedule_kind, local_time, enabled, updated_by)
  values
    (v_hh_id, 'daily_brief_weekday_morning', time '06:30', true, v_owner),
    (v_hh_id, 'daily_brief_nonworkday_morning', time '09:00', true, v_owner),
    (v_hh_id, 'daily_brief_evening', time '20:30', true, v_owner);

  v_slots := public.server_read_due_daily_brief_slots(timestamptz '2030-01-02 06:31+09');
  if not exists (
    select 1 from jsonb_array_elements(v_slots) e
    where e->>'household_id' = v_hh_id::text
      and e->>'recipient_user_id' = v_owner::text
      and e->>'schedule_kind' = 'daily_brief_weekday_morning'
      and e->>'local_time' = '06:30:00'
      and e->>'schedule_source' = 'base_schedule'
  ) then
    raise exception 'FAIL DD6: weekday 06:30 slot missing: %', v_slots;
  end if;

  insert into public.daily_brief_schedule_overrides
    (household_id, local_date, schedule_kind, enabled, local_time, updated_by)
  values (
    v_hh_id, date '2030-01-03', 'daily_brief_weekday_morning', true, time '07:15', v_owner
  );

  v_slots := public.server_read_due_daily_brief_slots(timestamptz '2030-01-03 07:00+09');
  if exists (
    select 1 from jsonb_array_elements(v_slots) e
    where e->>'household_id' = v_hh_id::text and e->>'schedule_kind' = 'daily_brief_weekday_morning'
  ) then
    raise exception 'FAIL DD6: one-date 07:15 override fired at 07:00: %', v_slots;
  end if;

  v_slots := public.server_read_due_daily_brief_slots(timestamptz '2030-01-03 07:16+09');
  if not exists (
    select 1 from jsonb_array_elements(v_slots) e
    where e->>'household_id' = v_hh_id::text
      and e->>'schedule_kind' = 'daily_brief_weekday_morning'
      and e->>'local_time' = '07:15:00'
      and e->>'schedule_source' = 'date_override'
  ) then
    raise exception 'FAIL DD6: one-date 07:15 override missing: %', v_slots;
  end if;

  -- DD7: production sender claims production/deliverable intent only. Direct
  -- test-context rows belong to the DD3A test outbox; in-app-only never calls LINE.
  insert into private.notification_outbox (
    id, household_id, recipient_user_id, channel, type, payload, dedup_key,
    urgency, test_context_id
  ) values
    (v_prod_outbox, v_hh_id, v_owner, 'line', 'dd7_prod', '{}'::jsonb, 'dd7-prod-' || v_owner::text, 'immediate', null),
    (v_test_outbox, v_hh_id, v_owner, 'line', 'dd7_test', '{}'::jsonb, 'dd7-test-' || v_owner::text, 'immediate', v_test_context),
    (v_inapp_outbox, v_hh_id, v_owner, 'line', 'dd7_inapp', '{}'::jsonb, 'dd7-inapp-' || v_owner::text, 'in_app_only', null);

  v_claim := public.server_tx_claim_notification_outbox_batch('dd7-worker', 20, 60);
  if not exists (
    select 1 from jsonb_array_elements(v_claim) e where e->>'id' = v_prod_outbox::text
  ) then
    raise exception 'FAIL DD7: production immediate intent was not claimable: %', v_claim;
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_claim) e
    where e->>'id' in (v_test_outbox::text, v_inapp_outbox::text)
  ) then
    raise exception 'FAIL DD7: test/in-app-only intent reached production sender: %', v_claim;
  end if;
  if (select status from private.notification_outbox where id = v_test_outbox) <> 'queued'
     or (select status from private.notification_outbox where id = v_inapp_outbox) <> 'queued' then
    raise exception 'FAIL DD7: excluded intents were mutated by production claim';
  end if;
end;
$$;

reset role;
select 'dd4_dd5_dd5b_dd6_dd7_e2e_read_models: PASS' as result;

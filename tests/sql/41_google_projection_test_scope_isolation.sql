-- WP-DD3A source-review HIGH regression: test Tasks cannot enqueue or influence
-- production Family Ops -> Google mirrors on INSERT, UPDATE, DELETE, reconcile,
-- or worker payload materialization.
\set ON_ERROR_STOP on

set role service_role;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_partner uuid := gen_random_uuid();
  v_hh jsonb;
  v_hh_id uuid;
  v_google_conn uuid;
  v_calendar_conn uuid;
  v_test_context uuid;
  v_owner_actor uuid;
  v_dropoff_def uuid;
  v_pickup_def uuid;
  v_test_task uuid;
  v_prod_dropoff uuid;
  v_prod_pickup uuid;
  v_claim jsonb;
  v_date date := '2026-09-15';
  v_before bigint;
begin
  insert into auth.users (id) values (v_owner), (v_partner);

  v_hh := public.server_tx_create_household(
    v_owner, gen_random_uuid(), 'DD3A Google isolation ' || v_owner::text, 'Owner'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, v_partner, 'adult');

  perform private.backfill_canonical_foundation_v1();
  select id into v_owner_actor
  from public.domain_actor_refs
  where household_id = v_hh_id and actor_kind = 'real_user' and real_user_id = v_owner;

  insert into public.test_simulation_contexts (household_id, operator_user_id, label)
  values (v_hh_id, v_owner, 'google-isolation') returning id into v_test_context;

  insert into private.google_connections
    (household_id, owner_user_id, google_subject, encrypted_refresh_token,
     encryption_version, scopes, status)
  values
    (v_hh_id, v_owner, 'google-isolation-41', 'cipher', 1,
     array['https://www.googleapis.com/auth/calendar.events'], 'active')
  returning id into v_google_conn;

  insert into public.calendar_connections
    (household_id, provider, external_calendar_id, google_connection_id, active, reauth_required)
  values
    (v_hh_id, 'google', 'isolation-41@group.calendar.google.com', v_google_conn, true, false)
  returning id into v_calendar_conn;

  perform public.server_tx_set_family_calendar_target(v_owner, gen_random_uuid(), v_calendar_conn);
  delete from private.family_ops_calendar_mirrors where household_id = v_hh_id;

  select id into v_dropoff_def
  from public.task_definitions where household_id = v_hh_id and code = 'dropoff';
  select id into v_pickup_def
  from public.task_definitions where household_id = v_hh_id and code = 'pickup';

  -- Test real-user transport Task is valid domain state. Its legacy mirror may
  -- contain the same real user UUID, but Google production projection must not
  -- consume it.
  select count(*) into v_before
  from private.family_ops_calendar_mirrors where household_id = v_hh_id;

  insert into public.task_instances (
    household_id, task_definition_id, origin, title, category, routine_phase,
    scheduled_date, planned_assignee_id, completion_mode, status, source, created_by,
    assignment_mode, assignment_source, planned_assignee_actor_ref_id, test_context_id
  ) values (
    v_hh_id, v_pickup_def, 'recurring', 'TEST pickup', 'pickup', 'evening',
    v_date, v_owner, 'whole', 'todo', 'test', v_owner,
    'person', 'canonical', v_owner_actor, v_test_context
  ) returning id into v_test_task;

  if (select count(*) from private.family_ops_calendar_mirrors where household_id = v_hh_id) <> v_before then
    raise exception 'FAIL google-test-isolation: test INSERT enqueued production mirror';
  end if;

  -- UPDATE must exercise a Google-trigger watched field while preserving the
  -- valid real-user ActorRef/legacy mirror pairing on the test Task.
  update public.task_instances
  set scheduled_date = v_date + 1
  where id = v_test_task;

  if (select count(*) from private.family_ops_calendar_mirrors where household_id = v_hh_id) <> v_before then
    raise exception 'FAIL google-test-isolation: test UPDATE enqueued production mirror';
  end if;

  delete from public.task_instances where id = v_test_task;

  if (select count(*) from private.family_ops_calendar_mirrors where household_id = v_hh_id) <> v_before then
    raise exception 'FAIL google-test-isolation: test DELETE enqueued production mirror';
  end if;

  -- Re-create a conflicting test pickup, then create production transport truth.
  -- The test row is newer and deliberately says owner/P; production pickup says
  -- partner/M. A leaking worker scan would render the wrong pickup token.
  insert into public.task_instances (
    household_id, task_definition_id, origin, title, category, routine_phase,
    scheduled_date, planned_assignee_id, completion_mode, status, source, created_by,
    assignment_mode, assignment_source, planned_assignee_actor_ref_id, test_context_id
  ) values (
    v_hh_id, v_pickup_def, 'recurring', 'TEST pickup newer', 'pickup', 'evening',
    v_date, v_owner, 'whole', 'todo', 'test', v_owner,
    'person', 'canonical', v_owner_actor, v_test_context
  ) returning id into v_test_task;

  insert into public.task_instances (
    household_id, task_definition_id, origin, title, category, routine_phase,
    scheduled_date, planned_assignee_id, completion_mode, status, source, created_by
  ) values (
    v_hh_id, v_dropoff_def, 'recurring', 'PROD dropoff', 'dropoff', 'morning',
    v_date, v_owner, 'whole', 'todo', 'test', v_owner
  ) returning id into v_prod_dropoff;

  insert into public.task_instances (
    household_id, task_definition_id, origin, title, category, routine_phase,
    scheduled_date, planned_assignee_id, completion_mode, status, source, created_by
  ) values (
    v_hh_id, v_pickup_def, 'recurring', 'PROD pickup', 'pickup', 'evening',
    v_date, v_partner, 'whole', 'todo', 'test', v_owner
  ) returning id into v_prod_pickup;

  -- Production reconciliation must enumerate only the two production Tasks.
  if (public.server_tx_reconcile_family_ops_calendar(v_hh_id, v_date, v_date)->>'queued_task_count')::int <> 2 then
    raise exception 'FAIL google-test-isolation: reconcile counted test Task';
  end if;

  -- Keep this household's transport row as the only claimable item.
  update private.family_ops_calendar_mirrors
  set next_attempt_at = now() + interval '1 day'
  where not (household_id = v_hh_id and projection_key = 'transport:' || v_date::text);

  v_claim := public.server_tx_claim_family_ops_calendar_mirror('sql-41', 120);
  if v_claim->>'household_id' <> v_hh_id::text
     or v_claim->>'action' <> 'upsert'
     or v_claim #>> '{event,summary}' <> '送 P ｜ 迎 M' then
    raise exception 'FAIL google-test-isolation: test transport influenced production payload: %', v_claim;
  end if;

  -- Special production lookup is also fail-closed: a test-scoped Task must not
  -- be materialized even if a stale/hostile special mirror somehow references it.
  insert into private.family_ops_calendar_mirrors (
    household_id, projection_key, kind, local_date, task_instance_id,
    calendar_connection_id, desired_action, sync_state, next_attempt_at
  ) values (
    v_hh_id, 'special:' || v_test_task::text, 'special', v_date, v_test_task,
    v_calendar_conn, 'upsert', 'pending', now()
  ) on conflict (household_id, projection_key) do update
    set sync_state = 'pending', desired_action = 'upsert', next_attempt_at = now();

  -- Finish/defer the first claimed production mirror so the hostile special row
  -- is deterministically next.
  perform public.server_tx_complete_family_ops_calendar_mirror(
    v_hh_id, 'transport:' || v_date::text, (v_claim->>'lease_token')::uuid,
    v_claim->>'deterministic_event_id', 'etag-41', false
  );
  update private.family_ops_calendar_mirrors
  set next_attempt_at = now() + interval '1 day'
  where not (household_id = v_hh_id and projection_key = 'special:' || v_test_task::text);

  v_claim := public.server_tx_claim_family_ops_calendar_mirror('sql-41-special', 120);
  if v_claim->>'action' <> 'delete' then
    raise exception 'FAIL google-test-isolation: test scoped Task materialized into production payload: %', v_claim;
  end if;
end;
$$;

reset role;
select '41_google_projection_test_scope_isolation: PASS' as result;

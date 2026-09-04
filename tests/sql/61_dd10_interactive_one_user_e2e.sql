\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid := '10000000-0000-0000-0000-000000000061';
  v_household uuid;
  v_context uuid;
  v_open jsonb;
  v_sent jsonb;
  v_accepted jsonb;
  v_completed jsonb;
  v_workspace jsonb;
  v_request_id uuid;
  v_attempt_id uuid;
  v_task_id uuid;
  v_attempt_revision bigint;
  v_terms_revision integer;
  v_task_revision bigint;
  v_prod_notifications_before bigint;
  v_prod_outbox_before bigint;
  v_google_before bigint;
begin
  insert into auth.users(id) values(v_owner) on conflict do nothing;
  insert into public.profiles(user_id,display_name) values(v_owner,'DD10 interactive owner') on conflict do nothing;
  perform public.server_tx_create_household(
    v_owner,
    '20000000-0000-0000-0000-000000000061',
    'DD10 interactive household',
    'Asia/Tokyo'
  );
  select household_id into v_household from public.household_members where user_id=v_owner;

  -- Browser-facing service RPCs must fail closed before the separately approved gate.
  begin
    perform public.server_tx_get_active_test_simulation_v1(v_owner);
    raise exception 'FAIL DD10 interactive: R0 allowed interactive reader';
  exception when others then
    if sqlerrm <> 'TEST_SIMULATION_CAPABILITY_NOT_ENABLED' then raise; end if;
  end;

  -- No public interactive RPC may accept an ActorRef parameter. Identity is
  -- always derived server-side from the authenticated operator + test context.
  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in (
        'server_tx_open_test_simulation_interactive_v1',
        'server_tx_get_active_test_simulation_v1',
        'server_tx_get_test_simulation_workspace_v2',
        'server_tx_test_simulation_send_request_v1',
        'server_tx_test_simulation_respond_request_v1',
        'server_tx_test_simulation_complete_task_v1',
        'server_tx_archive_test_simulation_interactive_v1'
      )
      and pg_get_function_arguments(p.oid) ilike '%actor_ref%'
  ) then
    raise exception 'FAIL DD10 interactive: browser RPC exposes ActorRef input';
  end if;

  select count(*) into v_prod_notifications_before from public.user_notifications;
  select count(*) into v_prod_outbox_before from private.notification_outbox;
  select count(*) into v_google_before from private.google_write_operations;

  update private.canonical_capability_gates
  set release_stage='P1', reader_enabled=true, writer_enabled=true,
      mutation_paused=false, p1_crossed_at=now(), updated_at=now()
  where capability='one_user_simulation_v1';

  v_open := public.server_tx_open_test_simulation_interactive_v1(
    v_owner,
    '20000000-0000-0000-0000-000000000161',
    'mama',
    'interactive E2E'
  );
  v_context := (v_open->>'test_context_id')::uuid;

  if (public.server_tx_get_active_test_simulation_v1(v_owner)->>'active')::boolean is not true then
    raise exception 'FAIL DD10 interactive: active context not discoverable';
  end if;

  -- Simulated -> operator proves the operator can safely exercise the recipient
  -- side without creating a second auth user/member. The simulated requester
  -- has no legacy user id; the real operator recipient deliberately retains
  -- their compatibility user id. test_context_id is the isolation boundary.
  v_sent := public.server_tx_test_simulation_send_request_v1(
    v_owner,
    v_context,
    '20000000-0000-0000-0000-000000000261',
    'simulated_to_operator',
    'テストお迎え',
    '1人テストからのお願い',
    now() + interval '1 day'
  );
  v_request_id := (v_sent->>'request_id')::uuid;
  v_attempt_id := (v_sent->>'attempt_id')::uuid;

  if not exists (
    select 1 from public.requests r
    where r.id=v_request_id
      and r.test_context_id=v_context
      and r.requester_id is null
      and r.recipient_id=v_owner
  ) then
    raise exception 'FAIL DD10 interactive: request escaped canonical test scope';
  end if;
  if not exists (
    select 1 from private.test_delivery_outbox d
    where d.test_context_id=v_context and d.operator_user_id=v_owner
  ) then
    raise exception 'FAIL DD10 interactive: synthetic request delivery missing';
  end if;
  if (select count(*) from public.user_notifications) <> v_prod_notifications_before
     or (select count(*) from private.notification_outbox) <> v_prod_outbox_before
     or (select count(*) from private.google_write_operations) <> v_google_before then
    raise exception 'FAIL DD10 interactive: production side effect leaked during request';
  end if;

  select revision,terms_revision into v_attempt_revision,v_terms_revision
  from public.request_attempts where id=v_attempt_id;
  v_accepted := public.server_tx_test_simulation_respond_request_v1(
    v_owner,
    v_context,
    '20000000-0000-0000-0000-000000000361',
    v_request_id,
    v_attempt_id,
    'accept',
    v_attempt_revision,
    v_terms_revision
  );
  v_task_id := (v_accepted->>'linked_task_id')::uuid;
  if v_task_id is null then raise exception 'FAIL DD10 interactive: accepted request did not create task'; end if;
  if not exists (
    select 1 from public.task_instances t
    where t.id=v_task_id and t.test_context_id=v_context and t.status in ('todo','in_progress')
  ) then
    raise exception 'FAIL DD10 interactive: linked task escaped test scope';
  end if;

  select revision into v_task_revision from public.task_instances where id=v_task_id;
  v_completed := public.server_tx_test_simulation_complete_task_v1(
    v_owner,
    v_context,
    '20000000-0000-0000-0000-000000000461',
    v_task_id,
    v_task_revision
  );
  if v_completed->>'status' <> 'completed' then raise exception 'FAIL DD10 interactive: task did not complete'; end if;
  if not exists (
    select 1 from public.task_actual_participants p
    where p.task_instance_id=v_task_id and p.test_context_id=v_context
  ) then
    raise exception 'FAIL DD10 interactive: completion performer not test scoped';
  end if;

  v_workspace := public.server_tx_get_test_simulation_workspace_v2(v_owner,v_context);
  if jsonb_array_length(v_workspace->'requests') < 1
     or jsonb_array_length(v_workspace->'tasks') < 1
     or jsonb_array_length(v_workspace->'deliveries') < 2
     or (v_workspace->>'production_side_effects')::boolean is not false then
    raise exception 'FAIL DD10 interactive: workspace does not expose isolated E2E state';
  end if;

  if (select count(*) from public.user_notifications) <> v_prod_notifications_before
     or (select count(*) from private.notification_outbox) <> v_prod_outbox_before
     or (select count(*) from private.google_write_operations) <> v_google_before then
    raise exception 'FAIL DD10 interactive: production side effect leaked after E2E';
  end if;

  perform public.server_tx_archive_test_simulation_interactive_v1(
    v_owner,
    '20000000-0000-0000-0000-000000000561',
    v_context,
    1
  );

  begin
    perform public.server_tx_test_simulation_send_request_v1(
      v_owner,
      v_context,
      '20000000-0000-0000-0000-000000000661',
      'operator_to_simulated',
      'archived mutation',
      null,
      null
    );
    raise exception 'FAIL DD10 interactive: archived context accepted mutation';
  exception when others then
    if sqlerrm <> 'TEST_CONTEXT_NOT_ACTIVE' then raise; end if;
  end;

  if exists (
    select 1 from public.domain_actor_refs a
    where a.test_context_id=v_context and a.actor_kind='simulated_member' and a.real_user_id is not null
  ) or exists (
    select 1 from public.household_members m
    where m.household_id=v_household and m.user_id<>v_owner
  ) then
    raise exception 'FAIL DD10 interactive: simulated identity became a production member';
  end if;

  -- Restore R0 so the lexically later DD11 final readiness gates stay strict.
  update private.canonical_capability_gates
  set release_stage='R0', reader_enabled=false, writer_enabled=false,
      mutation_paused=true, p1_crossed_at=null, updated_at=now()
  where capability='one_user_simulation_v1';
end;
$$;

reset role;
select '61_dd10_interactive_one_user_e2e: PASS' as result;

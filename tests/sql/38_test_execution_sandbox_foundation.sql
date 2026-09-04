-- WP-DD3A execution-context / synthetic-delivery foundation tests.
\set ON_ERROR_STOP on

set role service_role;

do $$
declare
  v_operator uuid := gen_random_uuid();
  v_partner uuid := gen_random_uuid();
  v_hh jsonb;
  v_hh_id uuid;
  v_test_context uuid;
  v_sim_mama uuid;
  v_real_operator_actor uuid;
  v_mode text;
  v_op uuid := gen_random_uuid();
  v_pending_id uuid;
begin
  insert into auth.users (id) values (v_operator), (v_partner);

  v_hh := public.server_tx_create_household(
    v_operator, gen_random_uuid(), 'DD3A Sandbox HH ' || v_operator::text, 'Owner'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, v_partner, 'adult');

  perform private.backfill_canonical_foundation_v1();
  select id into v_real_operator_actor
  from public.domain_actor_refs
  where household_id = v_hh_id and actor_kind = 'real_user' and real_user_id = v_operator;

  insert into public.test_simulation_contexts (household_id, operator_user_id, label)
  values (v_hh_id, v_operator, 'sandbox') returning id into v_test_context;

  insert into public.domain_actor_refs (
    household_id, actor_kind, test_context_id, simulated_role
  ) values (
    v_hh_id, 'simulated_member', v_test_context, 'mama'
  ) returning id into v_sim_mama;

  select private.fn_validate_execution_context_v1(
    v_hh_id, v_operator, v_sim_mama, v_test_context
  )->>'mode' into v_mode;
  if v_mode <> 'test_simulation' then
    raise exception 'FAIL dd3a: simulated execution context did not resolve as test_simulation';
  end if;

  begin
    perform private.fn_validate_execution_context_v1(
      v_hh_id, v_operator, v_sim_mama, null
    );
    raise exception 'FAIL dd3a: simulated actor was accepted as production execution';
  exception when others then
    if sqlerrm not like '%SIMULATED_ACTOR_IN_PRODUCTION_EXECUTION%' then raise; end if;
  end;

  begin
    perform private.fn_validate_execution_context_v1(
      v_hh_id, v_partner, v_sim_mama, v_test_context
    );
    raise exception 'FAIL dd3a: non-owner operator was accepted for test context';
  exception when others then
    if sqlerrm not like '%TEST_CONTEXT_OPERATOR_MISMATCH%' then raise; end if;
  end;

  -- Dedicated synthetic delivery is test-only and records semantic actor
  -- independently from the real operator destination/provenance.
  insert into private.test_delivery_outbox (
    household_id, test_context_id, operator_user_id, semantic_actor_ref_id,
    rendered_payload, dedup_key
  ) values (
    v_hh_id, v_test_context, v_operator, v_sim_mama,
    jsonb_build_object('text', '🧪 テスト: ママへの通知'),
    'request:test:' || v_op::text
  );

  if not exists (
    select 1 from private.test_delivery_outbox
    where test_context_id = v_test_context
      and operator_user_id = v_operator
      and semantic_actor_ref_id = v_sim_mama
      and delivery_mode = 'test_simulation'
      and status = 'queued'
  ) then
    raise exception 'FAIL dd3a: dedicated synthetic delivery row missing';
  end if;

  -- Canonical idempotency identity distinguishes production papa from the same
  -- operator executing as simulated mama inside a test context.
  insert into private.canonical_operation_receipts (
    household_id, operator_user_id, actor_ref_id, test_context_id,
    operation_id, action_type, request_hash
  ) values
    (v_hh_id, v_operator, v_real_operator_actor, null, v_op, 'task.complete', 'prod-hash'),
    (v_hh_id, v_operator, v_sim_mama, v_test_context, v_op, 'task.complete', 'test-hash');

  if (select count(*) from private.canonical_operation_receipts where operation_id = v_op) <> 2 then
    raise exception 'FAIL dd3a: production/test operation identities collided';
  end if;

  -- pending_actions.actor_id is operator provenance; actor_ref_id is domain actor.
  insert into private.pending_actions (
    household_id, actor_id, actor_ref_id, test_context_id, source, action_type,
    normalized_payload, operation_id, expires_at
  ) values (
    v_hh_id, v_operator, v_sim_mama, v_test_context, 'line', 'request.respond',
    '{}'::jsonb, gen_random_uuid(), now() + interval '5 minutes'
  ) returning id into v_pending_id;

  if not exists (
    select 1 from private.pending_actions
    where id = v_pending_id and actor_id = v_operator and actor_ref_id = v_sim_mama
  ) then
    raise exception 'FAIL dd3a: operator/domain-actor provenance was not preserved';
  end if;

  -- Existing mutation receipt also keeps operator in actor_id while canonical
  -- actor/test scope is independently validated.
  insert into private.mutation_receipts (
    actor_id, operation_id, action_type, request_hash, actor_ref_id, test_context_id
  ) values (
    v_operator, gen_random_uuid(), 'test.receipt', 'h', v_sim_mama, v_test_context
  );

  -- Archived contexts cannot authorize new test-scoped mutations/deliveries.
  update public.test_simulation_contexts
  set status = 'archived', archived_at = now()
  where id = v_test_context;

  begin
    insert into private.test_delivery_outbox (
      household_id, test_context_id, operator_user_id, semantic_actor_ref_id,
      rendered_payload, dedup_key
    ) values (
      v_hh_id, v_test_context, v_operator, v_sim_mama,
      jsonb_build_object('text', 'should fail'), 'archived:' || gen_random_uuid()::text
    );
    raise exception 'FAIL dd3a: archived test context authorized delivery';
  exception when others then
    if sqlerrm not like '%TEST_CONTEXT_NOT_ACTIVE%' then raise; end if;
  end;
end;
$$;

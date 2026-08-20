-- server_tx_* RPC transport boundary. docs/design/v6/15_DDL_CONTRACT.md #8;
-- fixtures/RLS_POLICY_MATRIX.md "v6 RPC/private-schema additions"
\set ON_ERROR_STOP on

insert into auth.users (id) values ('55555555-5555-5555-5555-555555555555');

-- anon cannot call server_tx_create_household
set role anon;
do $$
begin
  begin
    perform public.server_tx_create_household(
      '55555555-5555-5555-5555-555555555555', gen_random_uuid(), 'x', 'y'
    );
    raise exception 'FAIL rpc: anon must not be able to execute server_tx_create_household';
  exception
    when insufficient_privilege then null;
  end;
end;
$$;
reset role;

-- authenticated cannot call server_tx_create_household either (only
-- service_role, used exclusively by Edge Functions, may)
set role authenticated;
set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
do $$
begin
  begin
    perform public.server_tx_create_household(
      '55555555-5555-5555-5555-555555555555', gen_random_uuid(), 'x', 'y'
    );
    raise exception 'FAIL rpc: authenticated must not be able to execute server_tx_create_household directly';
  exception
    when insufficient_privilege then null;
  end;
end;
$$;

-- same for the LINE quota RPCs and the other two household RPCs
do $$
begin
  begin
    perform public.server_tx_join_household('55555555-5555-5555-5555-555555555555', gen_random_uuid(), 'tok', 'name');
    raise exception 'FAIL rpc: authenticated must not be able to execute server_tx_join_household directly';
  exception
    when insufficient_privilege then null;
  end;

  begin
    perform public.server_tx_create_household_invite('55555555-5555-5555-5555-555555555555', gen_random_uuid());
    raise exception 'FAIL rpc: authenticated must not be able to execute server_tx_create_household_invite directly';
  exception
    when insufficient_privilege then null;
  end;

  begin
    perform public.server_tx_reserve_line_quota(gen_random_uuid(), 'normal');
    raise exception 'FAIL rpc: authenticated must not be able to execute server_tx_reserve_line_quota directly';
  exception
    when insufficient_privilege then null;
  end;

  -- P1-2: the webhook/outbox RPCs are just as service_role-only as the rest
  begin
    perform public.server_tx_ingest_line_webhook_event('evt-1', 'Uxxxx', '{}'::jsonb);
    raise exception 'FAIL rpc: authenticated must not be able to execute server_tx_ingest_line_webhook_event directly';
  exception
    when insufficient_privilege then null;
  end;

  begin
    perform public.server_tx_count_queued_notifications();
    raise exception 'FAIL rpc: authenticated must not be able to execute server_tx_count_queued_notifications directly';
  exception
    when insufficient_privilege then null;
  end;
end;
$$;
reset role;
reset request.jwt.claim.sub;

set role anon;
do $$
begin
  begin
    perform public.server_tx_ingest_line_webhook_event('evt-1', 'Uxxxx', '{}'::jsonb);
    raise exception 'FAIL rpc: anon must not be able to execute server_tx_ingest_line_webhook_event';
  exception
    when insufficient_privilege then null;
  end;
end;
$$;
reset role;

-- service_role CAN execute them (this is how Edge Functions call them)
set role service_role;
do $$
declare
  v_result jsonb;
begin
  v_result := public.server_tx_create_household(
    '55555555-5555-5555-5555-555555555555', gen_random_uuid(), 'RPC Test Household', 'Tester'
  );
  if v_result->>'household_id' is null then
    raise exception 'FAIL rpc: service_role server_tx_create_household should succeed and return household_id';
  end if;
end;
$$;
reset role;

-- private tables: authenticated/anon cannot select even the ones with the
-- most sensitive content (tokens, refresh tokens, LINE links, OAuth state)
set role authenticated;
set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
do $$
declare
  t text;
  private_tables text[] := array[
    'line_user_links', 'google_oauth_states', 'household_invites',
    'line_link_tokens', 'notification_outbox', 'line_quota_state',
    'google_connections', 'mutation_receipts'
  ];
begin
  foreach t in array private_tables loop
    begin
      execute format('select 1 from private.%I limit 1', t);
      raise exception 'FAIL rpc: authenticated must not be able to select private.%', t;
    exception
      when insufficient_privilege then null;
    end;
  end loop;
end;
$$;
reset role;
reset request.jwt.claim.sub;

set role anon;
do $$
begin
  begin
    perform 1 from private.line_user_links limit 1;
    raise exception 'FAIL rpc: anon must not be able to select private.line_user_links';
  exception
    when insufficient_privilege then null;
  end;
end;
$$;
reset role;

select 'rpc_and_private_grants: PASS' as result;

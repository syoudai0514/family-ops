\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  actor uuid := gen_random_uuid();
  household uuid;
  connection uuid := gen_random_uuid();
  google_connection uuid := gen_random_uuid();
  create_op uuid := gen_random_uuid();
  first_update uuid := gen_random_uuid();
  second_update uuid := gen_random_uuid();
  event_id text;
  claimed jsonb;
begin
  insert into auth.users(id) values(actor);
  household := (public.server_tx_create_household(actor, gen_random_uuid(), 'Calendar write identity', 'Owner')->>'household_id')::uuid;
  insert into private.google_connections(id, household_id, owner_user_id, google_subject, encrypted_refresh_token, encryption_version, scopes, status)
  values(google_connection, household, actor, 'write-identity-subject', 'cipher', 1, array['https://www.googleapis.com/auth/calendar.events'], 'active');
  insert into public.calendar_connections(id, household_id, provider, external_calendar_id, google_connection_id)
  values(connection, household, 'google', 'write-identity@example.com', google_connection);

  claimed := public.server_tx_claim_google_write(actor, create_op, connection, 'create', 'create-hash', null);
  event_id := claimed->>'google_event_id';
  perform public.server_tx_finalize_google_write(create_op, 'succeeded', '"created"', null);

  -- Updating an event created by Family Ops must get a separate receipt.
  claimed := public.server_tx_claim_google_write(actor, first_update, connection, 'update', 'update-1', event_id);
  if claimed->>'status' <> 'pending' or claimed->>'google_event_id' <> event_id then
    raise exception 'FAIL: first update did not claim the created event: %', claimed;
  end if;
  perform public.server_tx_finalize_google_write(first_update, 'succeeded', '"updated-1"', null);

  -- An independent later edit must also work for the same provider event.
  claimed := public.server_tx_claim_google_write(actor, second_update, connection, 'update', 'update-2', event_id);
  if claimed->>'status' <> 'pending' then
    raise exception 'FAIL: second update did not get an independent pending receipt';
  end if;
  if (select count(*) from private.google_write_operations where calendar_connection_id = connection and google_event_id = event_id) <> 3 then
    raise exception 'FAIL: the event must retain all three operation receipts';
  end if;

  -- Retry of a completed operation must return its recorded outcome/etag.
  claimed := public.server_tx_claim_google_write(actor, first_update, connection, 'update', 'update-1', event_id);
  if claimed->>'status' <> 'succeeded' or claimed->>'result_etag' <> '"updated-1"' then
    raise exception 'FAIL: operation retry lost its result: %', claimed;
  end if;

  begin
    perform public.server_tx_claim_google_write(actor, first_update, connection, 'update', 'different-hash', event_id);
    raise exception 'FAIL: different payload must conflict';
  exception when others then
    if sqlerrm <> 'IDEMPOTENCY_CONFLICT' then raise; end if;
  end;
  begin
    perform public.server_tx_claim_google_write(actor, first_update, connection, 'update', 'update-1', 'different-event');
    raise exception 'FAIL: different target with equal hash must conflict';
  exception when others then
    if sqlerrm <> 'IDEMPOTENCY_CONFLICT' then raise; end if;
  end;
  begin
    perform public.server_tx_claim_google_write(actor, create_op, connection, 'update', 'create-hash', event_id);
    raise exception 'FAIL: different action with equal hash must conflict';
  exception when others then
    if sqlerrm <> 'IDEMPOTENCY_CONFLICT' then raise; end if;
  end;
end;
$$;
rollback;
select 'calendar_write_operation_identity: PASS' as result;

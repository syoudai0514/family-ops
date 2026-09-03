-- WP-DD2 regression: maintenance backfill can run after a canonical Request
-- command without adding a guessed legacy Attempt or violating active-attempt
-- uniqueness.
\set ON_ERROR_STOP on

set role service_role;

do $$
declare
  v_operator uuid := gen_random_uuid();
  v_recipient uuid := gen_random_uuid();
  v_household jsonb;
  v_household_id uuid;
  v_operator_actor uuid;
  v_recipient_actor uuid;
  v_created jsonb;
  v_request_id uuid;
  v_attempt_id uuid;
  v_first jsonb;
  v_second jsonb;
  v_missing bigint;
begin
  insert into auth.users(id) values (v_operator), (v_recipient);
  v_household := public.server_tx_create_household(
    v_operator,
    gen_random_uuid(),
    'Backfill coexistence ' || v_operator::text,
    'Operator'
  );
  v_household_id := (v_household->>'household_id')::uuid;

  insert into public.household_members(household_id, user_id, member_role)
  values (v_household_id, v_recipient, 'adult');

  -- This initial maintenance pass creates only deterministic real-user
  -- ActorRefs. It runs before this fixture's canonical Request exists.
  perform private.backfill_canonical_foundation_v1();

  select id into v_operator_actor
  from public.domain_actor_refs
  where household_id = v_household_id
    and actor_kind = 'real_user'
    and real_user_id = v_operator;

  select id into v_recipient_actor
  from public.domain_actor_refs
  where household_id = v_household_id
    and actor_kind = 'real_user'
    and real_user_id = v_recipient;

  v_created := private.fn_command_create_light_request_v1(
    v_household_id,
    v_operator,
    v_operator_actor,
    null,
    v_recipient_actor,
    'Canonical request',
    'Backfill must not invent another attempt',
    now() + interval '1 day',
    gen_random_uuid(),
    'pwa'
  );
  v_request_id := (v_created->>'request_id')::uuid;
  v_attempt_id := (v_created->>'attempt_id')::uuid;

  v_first := private.backfill_canonical_foundation_v1();
  v_second := private.backfill_canonical_foundation_v1();

  if (select count(*) from public.request_attempts where request_id = v_request_id) <> 1 then
    raise exception 'FAIL backfill-coexistence: canonical Request gained another Attempt';
  end if;
  if not exists (
    select 1 from public.request_attempts
    where request_id = v_request_id
      and id = v_attempt_id
      and not legacy_backfill
      and state = 'pending'
  ) then
    raise exception 'FAIL backfill-coexistence: canonical Attempt was changed';
  end if;
  if exists (
    select 1 from public.request_attempts
    where request_id = v_request_id and legacy_backfill
  ) then
    raise exception 'FAIL backfill-coexistence: legacy Attempt was invented';
  end if;
  if coalesce((v_first->>'request_attempts_inserted')::int, -1) <> 0
     or coalesce((v_second->>'request_attempts_inserted')::int, -1) <> 0 then
    raise exception 'FAIL backfill-coexistence: rerun reported guessed Request Attempts';
  end if;

  select issue_count into v_missing
  from private.canonical_foundation_reconciliation_v1()
  where issue_type = 'legacy_request_without_backfill_attempt';

  if coalesce(v_missing, -1) <> 0 then
    raise exception 'FAIL backfill-coexistence: canonical Attempt flagged as missing legacy backfill';
  end if;
end;
$$;

reset role;
select 'canonical_backfill_command_coexistence: PASS' as result;

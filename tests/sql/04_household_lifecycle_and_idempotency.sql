-- Household create/invite/join lifecycle + mutation idempotency.
-- docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #0, #0A;
-- fixtures/MUTATION_IDEMPOTENCY_CASES.json MI-HH01..04; fixtures/TOKEN_CASES.json T-01..04
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a0000000-0000-0000-0000-000000000001'), -- creator
  ('a0000000-0000-0000-0000-000000000002'), -- joiner 1 (fills 2nd seat)
  ('a0000000-0000-0000-0000-000000000003'); -- joiner 2 (rejected: household full)

set role service_role;

-- ---------------------------------------------------------------------------
-- create-household: happy path + replay + idempotency conflict (MI-HH01)
-- ---------------------------------------------------------------------------

do $$
declare
  v_op uuid := gen_random_uuid();
  v_r1 jsonb;
  v_r2 jsonb;
  v_hh uuid;
begin
  v_r1 := public.server_tx_create_household('a0000000-0000-0000-0000-000000000001', v_op, 'Test Household', 'Creator');
  v_hh := (v_r1->>'household_id')::uuid;
  if v_hh is null then
    raise exception 'FAIL household-create: no household_id returned';
  end if;

  -- exact same operation_id + same inputs => replay, same household id
  v_r2 := public.server_tx_create_household('a0000000-0000-0000-0000-000000000001', v_op, 'Test Household', 'Creator');
  if (v_r2->>'household_id')::uuid <> v_hh then
    raise exception 'FAIL household-create: replay must return the same household_id';
  end if;

  -- default routine schedules were seeded (no silent empty-night state)
  if (select count(*) from public.household_routine_schedules where household_id = v_hh) <> 8 then
    raise exception 'FAIL household-create: expected 8 seeded routine schedule rows';
  end if;

  -- same operation_id, different payload => IDEMPOTENCY_CONFLICT (MI-HH01 variant)
  begin
    perform public.server_tx_create_household('a0000000-0000-0000-0000-000000000001', v_op, 'Different Name', 'Creator');
    raise exception 'FAIL household-create: different payload with same operation_id must conflict';
  exception
    when others then
      if sqlerrm <> 'IDEMPOTENCY_CONFLICT' then
        raise exception 'FAIL household-create: expected IDEMPOTENCY_CONFLICT, got %', sqlerrm;
      end if;
  end;

  -- actor already has a household => a *new* operation_id still rejects with HOUSEHOLD_ALREADY_JOINED
  begin
    perform public.server_tx_create_household('a0000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Second HH', 'Creator');
    raise exception 'FAIL household-create: second household for same actor must be rejected';
  exception
    when others then
      if sqlerrm <> 'HOUSEHOLD_ALREADY_JOINED' then
        raise exception 'FAIL household-create: expected HOUSEHOLD_ALREADY_JOINED, got %', sqlerrm;
      end if;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- create-household-invite: raw token issuance + replay behavior
-- ---------------------------------------------------------------------------

do $$
declare
  v_op uuid := gen_random_uuid();
  v_r1 jsonb;
  v_raw_token text;
begin
  v_r1 := public.server_tx_create_household_invite('a0000000-0000-0000-0000-000000000001', v_op);
  v_raw_token := v_r1->>'raw_token';
  if v_raw_token is null or length(v_raw_token) <> 64 then
    raise exception 'FAIL invite-create: expected a 64-hex-char raw token, got %', v_raw_token;
  end if;

  -- raw token is never persisted anywhere (only its SHA-256 hash)
  if exists (select 1 from private.household_invites where token_hash = v_raw_token) then
    raise exception 'FAIL invite-create: raw token must never equal a stored token_hash';
  end if;

  -- replay: must not regenerate a token; must raise INVITE_TOKEN_ALREADY_ISSUED
  begin
    perform public.server_tx_create_household_invite('a0000000-0000-0000-0000-000000000001', v_op);
    raise exception 'FAIL invite-create: replay must raise INVITE_TOKEN_ALREADY_ISSUED, not succeed silently';
  exception
    when others then
      if sqlerrm <> 'INVITE_TOKEN_ALREADY_ISSUED' then
        raise exception 'FAIL invite-create: expected INVITE_TOKEN_ALREADY_ISSUED, got %', sqlerrm;
      end if;
  end;

  -- store the raw token for the join tests below via a temp table (psql session-local)
  create temporary table tmp_invite_token (raw_token text);
  insert into tmp_invite_token values (v_raw_token);
end;
$$;

-- ---------------------------------------------------------------------------
-- join-household: happy path fills the 2nd (last) adult seat
-- ---------------------------------------------------------------------------

do $$
declare
  v_token text;
  v_op uuid := gen_random_uuid();
  v_r jsonb;
  v_hh uuid;
begin
  select raw_token into v_token from tmp_invite_token;

  v_r := public.server_tx_join_household('a0000000-0000-0000-0000-000000000002', v_op, v_token, 'Joiner1');
  v_hh := (v_r->>'household_id')::uuid;
  if v_hh is null then
    raise exception 'FAIL join: expected household_id in result';
  end if;

  if (select count(*) from public.household_members where household_id = v_hh and member_role = 'adult') <> 2 then
    raise exception 'FAIL join: expected exactly 2 adults after join';
  end if;

  -- token now used: reuse must be rejected (T-02)
  begin
    perform public.server_tx_join_household('a0000000-0000-0000-0000-000000000003', gen_random_uuid(), v_token, 'Joiner2');
    raise exception 'FAIL join: reused invite token must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVITE_USED' then
        raise exception 'FAIL join: expected INVITE_USED, got %', sqlerrm;
      end if;
  end;
end;
$$;

-- HOUSEHOLD_FULL: a 3rd adult must be rejected even with a fresh valid invite
do $$
declare
  v_invite2 jsonb;
  v_token2 text;
begin
  v_invite2 := public.server_tx_create_household_invite('a0000000-0000-0000-0000-000000000001', gen_random_uuid());
  v_token2 := v_invite2->>'raw_token';

  begin
    perform public.server_tx_join_household('a0000000-0000-0000-0000-000000000003', gen_random_uuid(), v_token2, 'Joiner3');
    raise exception 'FAIL join: 3rd adult must be rejected (HOUSEHOLD_FULL)';
  exception
    when others then
      if sqlerrm <> 'HOUSEHOLD_FULL' then
        raise exception 'FAIL join: expected HOUSEHOLD_FULL, got %', sqlerrm;
      end if;
  end;
end;
$$;

-- expired invite token (T-03)
do $$
declare
  v_invite jsonb;
  v_token text;
  v_hash text;
begin
  v_invite := public.server_tx_create_household_invite('a0000000-0000-0000-0000-000000000002', gen_random_uuid());
  v_token := v_invite->>'raw_token';
  v_hash := encode(sha256(convert_to(v_token, 'UTF8')), 'hex');

  update private.household_invites set expires_at = now() - interval '1 minute' where token_hash = v_hash;

  begin
    perform public.server_tx_join_household('a0000000-0000-0000-0000-000000000003', gen_random_uuid(), v_token, 'Late');
    raise exception 'FAIL join: expired invite token must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVITE_EXPIRED' then
        raise exception 'FAIL join: expected INVITE_EXPIRED, got %', sqlerrm;
      end if;
  end;
end;
$$;

-- MI-HH02: same operation_id, different invite token => IDEMPOTENCY_CONFLICT.
-- Needs a *fresh* household with room, since the first join in this test
-- must actually succeed (and commit its receipt) before the replay-with-
-- different-payload path can be exercised.
do $$
declare
  v_owner uuid := 'a0000000-0000-0000-0000-000000000005';
  v_joiner uuid := 'a0000000-0000-0000-0000-000000000006';
  v_owner_hh jsonb;
  v_invite_a jsonb;
  v_invite_b jsonb;
  v_op uuid := gen_random_uuid();
begin
  insert into auth.users (id) values (v_owner), (v_joiner) on conflict do nothing;
  v_owner_hh := public.server_tx_create_household(v_owner, gen_random_uuid(), 'MI-HH02 Household', 'Owner');

  v_invite_a := public.server_tx_create_household_invite(v_owner, gen_random_uuid());
  v_invite_b := public.server_tx_create_household_invite(v_owner, gen_random_uuid());

  -- first call with invite A succeeds and commits the receipt
  perform public.server_tx_join_household(v_joiner, v_op, v_invite_a->>'raw_token', 'X');

  -- same operation_id, different invite token => IDEMPOTENCY_CONFLICT
  begin
    perform public.server_tx_join_household(v_joiner, v_op, v_invite_b->>'raw_token', 'X');
    raise exception 'FAIL join: same operation_id with a different invite token must conflict';
  exception
    when others then
      if sqlerrm <> 'IDEMPOTENCY_CONFLICT' then
        raise exception 'FAIL join: expected IDEMPOTENCY_CONFLICT, got %', sqlerrm;
      end if;
  end;
end;
$$;

select 'household_lifecycle_and_idempotency: PASS' as result;

-- WP5: Gemini AI-draft flow — raw_inputs storage + confirm-request-draft /
-- confirm-handover-draft writing the real requests/handovers row.
-- docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #13 "AI rewrite confirmation".
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('ad000000-0000-0000-0000-000000000001'), -- author / requester
  ('ad000000-0000-0000-0000-000000000002'), -- partner / recipient
  ('ad000000-0000-0000-0000-000000000003'); -- other household's member (cross-household)

set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_other_hh jsonb;
  v_other_hh_id uuid;
  v_result jsonb;
  v_raw_input_id uuid;
  v_request_id uuid;
  v_op_id uuid;
begin
  v_hh := public.server_tx_create_household('ad000000-0000-0000-0000-000000000001', gen_random_uuid(), 'AI Draft HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, 'ad000000-0000-0000-0000-000000000002', 'adult');

  v_other_hh := public.server_tx_create_household('ad000000-0000-0000-0000-000000000003', gen_random_uuid(), 'AI Draft Other HH', 'Owner');
  v_other_hh_id := (v_other_hh->>'household_id')::uuid;

  -- ---------------------------------------------------------------------
  -- server_tx_store_raw_input: happy path
  -- ---------------------------------------------------------------------
  v_result := public.server_tx_store_raw_input(
    'ad000000-0000-0000-0000-000000000001', gen_random_uuid(), 'request_draft',
    '牛乳を2本買ってきて、5月10日までにお願い', 24
  );
  v_raw_input_id := (v_result->>'raw_input_id')::uuid;
  if v_raw_input_id is null then
    raise exception 'FAIL ai-draft: store-raw-input must return a raw_input_id';
  end if;
  if not exists (
    select 1 from private.raw_inputs
    where id = v_raw_input_id and household_id = v_hh_id and author_user_id = 'ad000000-0000-0000-0000-000000000001'
      and kind = 'request_draft' and raw_text = '牛乳を2本買ってきて、5月10日までにお願い'
      and expires_at > now()
  ) then
    raise exception 'FAIL ai-draft: raw_inputs row must be stored with the given kind/raw_text/expiry';
  end if;

  -- store-raw-input rejects an unknown kind
  begin
    perform public.server_tx_store_raw_input('ad000000-0000-0000-0000-000000000001', gen_random_uuid(), 'bogus_kind', 'x', 24);
    raise exception 'FAIL ai-draft: an unknown raw_input kind must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL ai-draft: expected INVALID_INPUT, got %', sqlerrm;
      end if;
  end;

  -- ---------------------------------------------------------------------
  -- confirm-request-draft: happy path — writes the real requests row with
  -- the user's confirmed (possibly AI-proposal-edited) text, never the raw
  -- private text directly.
  -- ---------------------------------------------------------------------
  v_op_id := gen_random_uuid();
  v_result := public.server_tx_confirm_request_draft(
    'ad000000-0000-0000-0000-000000000001', v_op_id, v_raw_input_id,
    'ad000000-0000-0000-0000-000000000002', '牛乳の買い物', '牛乳を2本、5月10日までにお願いします', null
  );
  v_request_id := (v_result->>'request_id')::uuid;
  if v_request_id is null then
    raise exception 'FAIL ai-draft: confirm-request-draft must return a request_id';
  end if;
  if (select shared_title from public.requests where id = v_request_id) <> '牛乳の買い物' then
    raise exception 'FAIL ai-draft: confirm-request-draft must write the confirmed shared_title';
  end if;
  if (select shared_message from public.requests where id = v_request_id) <> '牛乳を2本、5月10日までにお願いします' then
    raise exception 'FAIL ai-draft: confirm-request-draft must write the user-confirmed text, not the raw private text';
  end if;
  if (select status from public.requests where id = v_request_id) <> 'pending' then
    raise exception 'FAIL ai-draft: confirm-request-draft must create a pending request';
  end if;
  if not exists (
    select 1 from public.user_notifications
    where household_id = v_hh_id and recipient_user_id = 'ad000000-0000-0000-0000-000000000002' and type = 'request_received'
  ) then
    raise exception 'FAIL ai-draft: confirm-request-draft must notify the recipient (via server_tx_send_request)';
  end if;

  -- replay with the SAME operation_id + same input returns the cached
  -- result and does not create a second request row
  v_result := public.server_tx_confirm_request_draft(
    'ad000000-0000-0000-0000-000000000001', v_op_id, v_raw_input_id,
    'ad000000-0000-0000-0000-000000000002', '牛乳の買い物', '牛乳を2本、5月10日までにお願いします', null
  );
  if (v_result->>'request_id')::uuid <> v_request_id then
    raise exception 'FAIL ai-draft: replaying confirm-request-draft must return the same request_id';
  end if;
  if (select count(*) from public.requests where household_id = v_hh_id and shared_title = '牛乳の買い物') <> 1 then
    raise exception 'FAIL ai-draft: replaying confirm-request-draft must not create a second request';
  end if;

  -- same operation_id, DIFFERENT content -> IDEMPOTENCY_CONFLICT
  begin
    perform public.server_tx_confirm_request_draft(
      'ad000000-0000-0000-0000-000000000001', v_op_id, v_raw_input_id,
      'ad000000-0000-0000-0000-000000000002', '別のタイトル', '別の本文です', null
    );
    raise exception 'FAIL ai-draft: reusing operation_id with different content must be rejected';
  exception
    when others then
      if sqlerrm <> 'IDEMPOTENCY_CONFLICT' then
        raise exception 'FAIL ai-draft: expected IDEMPOTENCY_CONFLICT, got %', sqlerrm;
      end if;
  end;

  -- confirming the same raw_input a second time (new operation_id) is
  -- allowed — raw_inputs carries no consumed-flag per the v5-exact DDL —
  -- and creates an independent second request.
  v_result := public.server_tx_confirm_request_draft(
    'ad000000-0000-0000-0000-000000000001', gen_random_uuid(), v_raw_input_id,
    'ad000000-0000-0000-0000-000000000002', '牛乳の買い物その2', '牛乳を2本、5月10日までにお願いします', null
  );
  if (select count(*) from public.requests where household_id = v_hh_id and shared_title = '牛乳の買い物その2') <> 1 then
    raise exception 'FAIL ai-draft: a fresh operation_id against the same raw_input must create a new request';
  end if;

  -- confirm-request-draft rejects a raw_input that belongs to a DIFFERENT
  -- household (never leaks existence — same code as a missing id)
  begin
    perform public.server_tx_confirm_request_draft(
      'ad000000-0000-0000-0000-000000000003', gen_random_uuid(), v_raw_input_id,
      'ad000000-0000-0000-0000-000000000003', 'x', 'y', null
    );
    raise exception 'FAIL ai-draft: confirm-request-draft across households must be rejected';
  exception
    when others then
      if sqlerrm <> 'CROSS_HOUSEHOLD_RESOURCE' then
        raise exception 'FAIL ai-draft: expected CROSS_HOUSEHOLD_RESOURCE, got %', sqlerrm;
      end if;
  end;

  -- confirm-request-draft rejects a raw_input authored by someone else in
  -- the SAME household (private per-author text)
  declare
    v_partner_raw jsonb;
    v_partner_raw_id uuid;
  begin
    v_partner_raw := public.server_tx_store_raw_input(
      'ad000000-0000-0000-0000-000000000002', gen_random_uuid(), 'request_draft', 'partner private text', 24
    );
    v_partner_raw_id := (v_partner_raw->>'raw_input_id')::uuid;

    begin
      perform public.server_tx_confirm_request_draft(
        'ad000000-0000-0000-0000-000000000001', gen_random_uuid(), v_partner_raw_id,
        'ad000000-0000-0000-0000-000000000002', 'x', 'y', null
      );
      raise exception 'FAIL ai-draft: confirming a raw_input authored by a different household member must be rejected';
    exception
      when others then
        if sqlerrm <> 'CROSS_HOUSEHOLD_RESOURCE' then
          raise exception 'FAIL ai-draft: expected CROSS_HOUSEHOLD_RESOURCE, got %', sqlerrm;
        end if;
    end;
  end;

  -- confirm-request-draft rejects a handover_draft-kind raw_input (kind mismatch)
  declare
    v_wrong_kind jsonb;
    v_wrong_kind_id uuid;
  begin
    v_wrong_kind := public.server_tx_store_raw_input(
      'ad000000-0000-0000-0000-000000000001', gen_random_uuid(), 'handover_draft', 'not a request draft', 24
    );
    v_wrong_kind_id := (v_wrong_kind->>'raw_input_id')::uuid;

    begin
      perform public.server_tx_confirm_request_draft(
        'ad000000-0000-0000-0000-000000000001', gen_random_uuid(), v_wrong_kind_id,
        'ad000000-0000-0000-0000-000000000002', 'x', 'y', null
      );
      raise exception 'FAIL ai-draft: confirm-request-draft must reject a raw_input whose kind is not request_draft';
    exception
      when others then
        if sqlerrm <> 'INVALID_INPUT' then
          raise exception 'FAIL ai-draft: expected INVALID_INPUT, got %', sqlerrm;
        end if;
    end;
  end;

  -- confirm-request-draft rejects an EXPIRED raw_input
  declare
    v_expiring jsonb;
    v_expiring_id uuid;
  begin
    v_expiring := public.server_tx_store_raw_input(
      'ad000000-0000-0000-0000-000000000001', gen_random_uuid(), 'request_draft', 'about to expire', 24
    );
    v_expiring_id := (v_expiring->>'raw_input_id')::uuid;
    update private.raw_inputs set expires_at = now() - interval '1 hour' where id = v_expiring_id;

    begin
      perform public.server_tx_confirm_request_draft(
        'ad000000-0000-0000-0000-000000000001', gen_random_uuid(), v_expiring_id,
        'ad000000-0000-0000-0000-000000000002', 'x', 'y', null
      );
      raise exception 'FAIL ai-draft: confirm-request-draft must reject an expired raw_input';
    exception
      when others then
        if sqlerrm <> 'RAW_INPUT_EXPIRED' then
          raise exception 'FAIL ai-draft: expected RAW_INPUT_EXPIRED, got %', sqlerrm;
        end if;
    end;
  end;
end;
$$;

-- ---------------------------------------------------------------------
-- confirm-handover-draft: happy path + replay
-- ---------------------------------------------------------------------
do $$
declare
  v_hh_id uuid;
  v_raw jsonb;
  v_raw_id uuid;
  v_result jsonb;
  v_handover_id uuid;
  v_op_id uuid;
begin
  select id into v_hh_id from public.households where name = 'AI Draft HH';

  v_raw := public.server_tx_store_raw_input(
    'ad000000-0000-0000-0000-000000000001', gen_random_uuid(), 'handover_draft',
    '今日は保育園のお迎えとお風呂を担当しました', 24
  );
  v_raw_id := (v_raw->>'raw_input_id')::uuid;

  v_op_id := gen_random_uuid();
  v_result := public.server_tx_confirm_handover_draft(
    'ad000000-0000-0000-0000-000000000001', v_op_id, v_raw_id,
    '今日は保育園のお迎えとお風呂を担当しました', 'evening', array['childcare'], current_date
  );
  v_handover_id := (v_result->>'handover_id')::uuid;
  if v_handover_id is null then
    raise exception 'FAIL ai-draft: confirm-handover-draft must return a handover_id';
  end if;
  if (select shared_text from public.handovers where id = v_handover_id) <> '今日は保育園のお迎えとお風呂を担当しました' then
    raise exception 'FAIL ai-draft: confirm-handover-draft must write the confirmed shared_text';
  end if;
  if (select author_id from public.handovers where id = v_handover_id) <> 'ad000000-0000-0000-0000-000000000001' then
    raise exception 'FAIL ai-draft: confirm-handover-draft must attribute authorship to the actor';
  end if;
  if not exists (
    select 1 from public.user_notifications
    where household_id = v_hh_id and recipient_user_id = 'ad000000-0000-0000-0000-000000000002' and type = 'handover_created'
  ) then
    raise exception 'FAIL ai-draft: confirm-handover-draft must notify other household members';
  end if;

  -- replay with the SAME operation_id returns the cached result, no
  -- second handover row
  v_result := public.server_tx_confirm_handover_draft(
    'ad000000-0000-0000-0000-000000000001', v_op_id, v_raw_id,
    '今日は保育園のお迎えとお風呂を担当しました', 'evening', array['childcare'], current_date
  );
  if (v_result->>'handover_id')::uuid <> v_handover_id then
    raise exception 'FAIL ai-draft: replaying confirm-handover-draft must return the same handover_id';
  end if;
  if (select count(*) from public.handovers where household_id = v_hh_id and shared_text = '今日は保育園のお迎えとお風呂を担当しました') <> 1 then
    raise exception 'FAIL ai-draft: replaying confirm-handover-draft must not create a second handover';
  end if;

  -- confirm-handover-draft rejects a request_draft-kind raw_input
  declare
    v_wrong_kind jsonb;
    v_wrong_kind_id uuid;
  begin
    v_wrong_kind := public.server_tx_store_raw_input(
      'ad000000-0000-0000-0000-000000000001', gen_random_uuid(), 'request_draft', 'not a handover draft', 24
    );
    v_wrong_kind_id := (v_wrong_kind->>'raw_input_id')::uuid;

    begin
      perform public.server_tx_confirm_handover_draft(
        'ad000000-0000-0000-0000-000000000001', gen_random_uuid(), v_wrong_kind_id,
        'x', 'evening', null, current_date
      );
      raise exception 'FAIL ai-draft: confirm-handover-draft must reject a raw_input whose kind is not handover_draft';
    exception
      when others then
        if sqlerrm <> 'INVALID_INPUT' then
          raise exception 'FAIL ai-draft: expected INVALID_INPUT, got %', sqlerrm;
        end if;
    end;
  end;
end;
$$;

reset role;
select 'ai_draft_mutations: PASS' as result;

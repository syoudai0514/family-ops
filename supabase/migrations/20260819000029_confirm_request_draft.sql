-- WP5: Gemini AI-draft flow, part 2 — confirm-request-draft.
-- docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #13 "AI rewrite
-- confirmation": author must confirm transformed text; shared row created
-- only after confirmation; recipient never sees private raw text.
--
-- Writes the real public.requests row by delegating to the already-
-- implemented, already-reviewed WP2 public.server_tx_send_request, under a
-- *derived* sub-operation-id (md5(p_operation_id || ':server_tx_send_request')
-- cast to uuid) rather than duplicating its insert logic. The derivation is
-- required, not cosmetic: private.mutation_receipts primary-keys on
-- (actor_id, operation_id) alone (no action_type in the key), so calling
-- server_tx_send_request with the caller-supplied p_operation_id unchanged
-- would collide with this function's own claim row on the very first call.
-- See docs/adr/0003-ai-draft-propose-endpoint.md.

create or replace function public.server_tx_confirm_request_draft(
  p_actor_id uuid,
  p_operation_id uuid,
  p_raw_input_id uuid,
  p_recipient_user_id uuid,
  p_shared_title text,
  p_confirmed_message text,
  p_due_at timestamptz
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_raw_input record;
  v_sub_operation_id uuid;
  v_inner_result jsonb;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_raw_input_id is null
     or p_recipient_user_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if coalesce(btrim(p_shared_title), '') = '' or coalesce(btrim(p_confirmed_message), '') = '' then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'confirm-request-draft|' || p_raw_input_id::text || '|' || p_recipient_user_id::text
        || '|' || p_shared_title || '|' || p_confirmed_message,
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'confirm-request-draft', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;

    if found then
      exit;
    end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;

    if found then
      if v_receipt.request_hash <> v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  -- Only the raw_input's own author may confirm it (private per-author text,
  -- never exposed to other household members even within the same
  -- household — docs/design/v6/04_SECURITY_RLS_PRIVACY.md #9). A mismatched
  -- household or a different author both look like "not found" rather than
  -- leaking existence.
  select * into v_raw_input
  from private.raw_inputs
  where id = p_raw_input_id and household_id = v_household_id and author_user_id = p_actor_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_raw_input.kind <> 'request_draft' then
    raise exception 'INVALID_INPUT';
  end if;
  if v_raw_input.expires_at <= now() then
    raise exception 'RAW_INPUT_EXPIRED';
  end if;

  v_sub_operation_id := md5(p_operation_id::text || ':server_tx_send_request')::uuid;

  v_inner_result := public.server_tx_send_request(
    p_actor_id, v_sub_operation_id, p_recipient_user_id, p_shared_title, p_confirmed_message, p_due_at
  );

  v_result := v_inner_result;

  update private.mutation_receipts
  set result_type = 'request', result_id = (v_inner_result->>'request_id')::uuid, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_confirm_request_draft(uuid, uuid, uuid, uuid, text, text, timestamptz) from public;
revoke all on function public.server_tx_confirm_request_draft(uuid, uuid, uuid, uuid, text, text, timestamptz) from anon;
revoke all on function public.server_tx_confirm_request_draft(uuid, uuid, uuid, uuid, text, text, timestamptz) from authenticated;
grant execute on function public.server_tx_confirm_request_draft(uuid, uuid, uuid, uuid, text, text, timestamptz) to service_role;

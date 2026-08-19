-- WP5: Gemini AI-draft flow, part 3 — confirm-handover-draft.
-- Same rationale/pattern as confirm-request-draft
-- (20260819000029_confirm_request_draft.sql) and
-- docs/adr/0003-ai-draft-propose-endpoint.md, delegating to the
-- already-implemented, already-reviewed WP2 public.server_tx_create_handover
-- under a derived sub-operation-id.

create or replace function public.server_tx_confirm_handover_draft(
  p_actor_id uuid,
  p_operation_id uuid,
  p_raw_input_id uuid,
  p_confirmed_text text,
  p_period text,
  p_categories text[],
  p_occurred_on date
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
  if p_actor_id is null or p_operation_id is null or p_raw_input_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if coalesce(btrim(p_confirmed_text), '') = '' or p_occurred_on is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'confirm-handover-draft|' || p_raw_input_id::text || '|' || p_confirmed_text
        || '|' || p_occurred_on::text,
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'confirm-handover-draft', v_request_hash)
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

  -- Only the raw_input's own author may confirm it (see
  -- confirm-request-draft for the same rationale).
  select * into v_raw_input
  from private.raw_inputs
  where id = p_raw_input_id and household_id = v_household_id and author_user_id = p_actor_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_raw_input.kind <> 'handover_draft' then
    raise exception 'INVALID_INPUT';
  end if;
  if v_raw_input.expires_at <= now() then
    raise exception 'RAW_INPUT_EXPIRED';
  end if;

  v_sub_operation_id := md5(p_operation_id::text || ':server_tx_create_handover')::uuid;

  v_inner_result := public.server_tx_create_handover(
    p_actor_id, v_sub_operation_id, p_confirmed_text, p_period, p_categories, p_occurred_on
  );

  v_result := v_inner_result;

  update private.mutation_receipts
  set result_type = 'handover', result_id = (v_inner_result->>'handover_id')::uuid, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_confirm_handover_draft(uuid, uuid, uuid, text, text, text[], date) from public;
revoke all on function public.server_tx_confirm_handover_draft(uuid, uuid, uuid, text, text, text[], date) from anon;
revoke all on function public.server_tx_confirm_handover_draft(uuid, uuid, uuid, text, text, text[], date) from authenticated;
grant execute on function public.server_tx_confirm_handover_draft(uuid, uuid, uuid, text, text, text[], date) to service_role;

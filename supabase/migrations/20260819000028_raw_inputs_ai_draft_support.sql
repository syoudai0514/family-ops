-- WP5: Gemini AI-draft flow, part 1 — private.raw_inputs support +
-- server_tx_store_raw_input (the storage half of "propose-ai-draft";
-- docs/adr/0003-ai-draft-propose-endpoint.md).
--
-- private.raw_inputs itself already exists exactly per
-- docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md's v5-exact DDL (migrated in
-- 20260819000006_private_queues_tokens.sql, columns unchanged here — no v7
-- schema invention). This migration only adds an index supporting the
-- author-scoped lookup confirm-request-draft/confirm-handover-draft need,
-- and the claim-then-fill mutation that writes a raw_inputs row.
--
-- Same server_tx_* pattern as every other mutation in this repo:
-- private.mutation_receipts claim-then-fill idempotency, SECURITY INVOKER,
-- set search_path = '', EXECUTE revoked from public/anon/authenticated,
-- granted to service_role only.

create index raw_inputs_household_author_created_idx
  on private.raw_inputs (household_id, author_user_id, created_at);

-- ---------------------------------------------------------------------------
-- store-raw-input (called from propose-ai-draft, before the Gemini call)
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_store_raw_input(
  p_actor_id uuid,
  p_operation_id uuid,
  p_kind text,
  p_raw_text text,
  p_ttl_hours int
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
  v_raw_input_id uuid;
  v_expires_at timestamptz;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_kind not in ('request_draft', 'handover_draft', 'natural_language') then
    raise exception 'INVALID_INPUT';
  end if;
  if coalesce(btrim(p_raw_text), '') = '' then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to('store-raw-input|' || p_kind || '|' || p_raw_text, 'UTF8')),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'store-raw-input', v_request_hash)
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

  v_expires_at := now() + make_interval(hours => greatest(coalesce(p_ttl_hours, 24), 1));

  insert into private.raw_inputs
    (household_id, author_user_id, kind, raw_text, expires_at)
  values
    (v_household_id, p_actor_id, p_kind, p_raw_text, v_expires_at)
  returning id into v_raw_input_id;

  v_result := jsonb_build_object('raw_input_id', v_raw_input_id, 'expires_at', v_expires_at);

  update private.mutation_receipts
  set result_type = 'raw_input', result_id = v_raw_input_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_store_raw_input(uuid, uuid, text, text, int) from public;
revoke all on function public.server_tx_store_raw_input(uuid, uuid, text, text, int) from anon;
revoke all on function public.server_tx_store_raw_input(uuid, uuid, text, text, int) from authenticated;
grant execute on function public.server_tx_store_raw_input(uuid, uuid, text, text, int) to service_role;

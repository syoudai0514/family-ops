-- 家族のLINEを、本人に代わって付け替える (owner request 2026-11-17).
--
-- Live: the second adult ("ママ（仮）") was a stand-in the owner set up to try the app, with a LINE
-- account of its own. The real partner has not used it yet. Her seat -- the member id, the
-- weekly transport template (火・水 迎え, 木 送り迎え), 657 planned tasks -- stays as it is: the
-- canonical identity (domain_actor_refs) is deliberately immutable and 54 tables point at the
-- member row, so moving the seat to a new account would fight the model. What changes hands is
-- the LINE account behind the seat:
--  * server_tx_release_member_line: the other adult's LINE link is removed (deleted, so the LINE
--    id is free to link again -- UNIQUE(line_user_id) counts unlinked rows too) together with
--    unused link codes and the stand-in's LINE conversation memory.
--  * server_tx_create_member_line_link_token: a link code for the other adult, valid 7 days
--    instead of 10 minutes, so it can be sent to someone who links when it suits them. Whoever
--    sends it to the おうちノート LINE takes that seat's LINE (the existing claim path).

create or replace function private.fn_require_other_member_v1(p_actor_id uuid, p_member_user_id uuid)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare v_household uuid;
begin
  if p_actor_id is null or p_member_user_id is null or p_actor_id = p_member_user_id then
    raise exception 'INVALID_INPUT';
  end if;
  select household_id into v_household from public.household_members where user_id = p_actor_id;
  if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  if not exists (select 1 from public.household_members where household_id = v_household and user_id = p_member_user_id) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  return v_household;
end $$;
revoke all on function private.fn_require_other_member_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function private.fn_require_other_member_v1(uuid, uuid) to service_role;

create or replace function public.server_tx_release_member_line(
  p_actor_id uuid, p_operation_id uuid, p_member_user_id uuid
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_household uuid; v_hash text; v_receipt private.mutation_receipts%rowtype; v_result jsonb; v_had boolean;
begin
  if p_operation_id is null then raise exception 'INVALID_INPUT'; end if;
  v_household := private.fn_require_other_member_v1(p_actor_id, p_member_user_id);
  v_hash := encode(sha256(convert_to('release-member-line|' || p_member_user_id::text, 'UTF8')), 'hex');
  insert into private.mutation_receipts(actor_id, operation_id, action_type, request_hash)
  values (p_actor_id, p_operation_id, 'release-member-line', v_hash) on conflict (actor_id, operation_id) do nothing;
  if not found then
    select * into v_receipt from private.mutation_receipts where actor_id = p_actor_id and operation_id = p_operation_id for update;
    if v_receipt.request_hash <> v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result_payload;
  end if;
  v_had := exists (select 1 from private.line_user_links where user_id = p_member_user_id);
  delete from private.line_user_links where user_id = p_member_user_id;
  delete from private.line_link_tokens where user_id = p_member_user_id and used_at is null;
  delete from private.line_conversation_turns where actor_id = p_member_user_id;
  v_result := jsonb_build_object('ok', true, 'member_user_id', p_member_user_id, 'released', v_had);
  update private.mutation_receipts set result_type = 'household', result_id = v_household, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;
  return v_result;
end $$;
revoke all on function public.server_tx_release_member_line(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.server_tx_release_member_line(uuid, uuid, uuid) to service_role;

create or replace function public.server_tx_create_member_line_link_token(
  p_actor_id uuid, p_operation_id uuid, p_member_user_id uuid
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_household uuid; v_raw text; v_id uuid; v_expires timestamptz := now() + interval '7 days';
begin
  if p_operation_id is null then raise exception 'INVALID_INPUT'; end if;
  v_household := private.fn_require_other_member_v1(p_actor_id, p_member_user_id);
  if exists (select 1 from private.line_user_links where user_id = p_member_user_id and status = 'active') then
    raise exception 'MEMBER_LINE_ALREADY_LINKED';
  end if;
  -- The raw code is returned once and never stored, so a retried operation id cannot replay it.
  insert into private.mutation_receipts(actor_id, operation_id, action_type, request_hash)
  values (p_actor_id, p_operation_id, 'create-member-line-link-token',
    encode(sha256(convert_to('create-member-line-link-token|' || p_member_user_id::text, 'UTF8')), 'hex'))
  on conflict (actor_id, operation_id) do nothing;
  if not found then raise exception 'INVALID_INPUT'; end if;
  -- One live code per person: a new one retires the earlier ones.
  update private.line_link_tokens set expires_at = least(expires_at, now())
  where user_id = p_member_user_id and used_at is null;
  v_raw := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into private.line_link_tokens (token_hash, household_id, user_id, expires_at)
  values (encode(sha256(convert_to(v_raw, 'UTF8')), 'hex'), v_household, p_member_user_id, v_expires)
  returning id into v_id;
  update private.mutation_receipts set result_type = 'line_link_token', result_id = v_id,
    result_payload = jsonb_build_object('token_id', v_id, 'household_id', v_household)
  where actor_id = p_actor_id and operation_id = p_operation_id;
  return jsonb_build_object('token_id', v_id, 'household_id', v_household, 'member_user_id', p_member_user_id,
    'raw_token', v_raw, 'expires_at', v_expires);
end $$;
revoke all on function public.server_tx_create_member_line_link_token(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.server_tx_create_member_line_link_token(uuid, uuid, uuid) to service_role;

-- Owner decisions, 2026-09-30.
--
-- 1. "コドモンを送信した" ends the Codmon job, whatever the ticks in the app say.
--    Live: "コドモン送りました！" over LINE was refused with "コドモンの入力が
--    そろっていません" because the four input tasks had not been ticked in the
--    PWA. Codmon itself had already been sent, so the only way to record it was
--    to open the PWA and tick four boxes first -- the opposite of the goal that
--    LINE alone is enough.
--
--    The final-send invariant (12_CODMON_DAILY_SUBMISSION.md §5, enforced by
--    the codmon_submit completion guard) is KEPT: a completed codmon_submit
--    still implies four completed inputs. What changes is the acknowledgement:
--    server_tx_acknowledge_codmon_submission_v1 closes the still-open inputs
--    and then the submit task in ONE transaction, each through the canonical
--    server_tx_complete_task (same events, receipts and performer rules as a
--    normal completion). Unticked inputs are recorded as done by the SENDER
--    (owner decision 2026-09-30), except the ones the sender says were already
--    done ("朝食はやってあった"): those are recorded as done by the other adult
--    (p_partner_input_codes).
--
-- 2. Any adult in the household can end (clear) a handover -- Requirements
--    §8.2 "クリアするまで" (owner decision 2026-09-30: not only the author).
--    Live: 【言語通級】 (written 2026-08-24, period 'day', no valid_until) was
--    still listed as 未読の引き継ぎ five weeks later. Nothing could end it: the
--    status column allows 'expired' but no command ever set it.
--    server_tx_end_handover sets status='expired'; the row stays as history
--    (§8.6: invalidate, never delete).

create or replace function public.server_tx_acknowledge_codmon_submission_v1(
  p_actor_id uuid,
  p_operation_id uuid,
  p_submit_task_id uuid,
  p_source text default 'pwa',
  p_partner_input_codes text[] default null
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_task public.task_instances%rowtype;
  v_code text;
  v_readiness jsonb;
  v_input jsonb;
  v_input_task uuid;
  v_has_partner boolean;
  v_by_partner boolean;
  v_closed integer := 0;
  v_closed_by_partner integer := 0;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_submit_task_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if coalesce(p_source, 'pwa') not in ('pwa', 'line') then raise exception 'INVALID_INPUT'; end if;

  select m.household_id into v_household_id
  from public.household_members m where m.user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select * into v_task from public.task_instances
  where household_id = v_household_id and id = p_submit_task_id;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_task.test_context_id is not null then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;

  select td.code into v_code from public.task_definitions td
  where td.household_id = v_household_id and td.id = v_task.task_definition_id;
  if v_code is distinct from 'codmon_submit' then raise exception 'INVALID_INPUT'; end if;

  select exists (
    select 1 from public.household_members m
    where m.household_id = v_household_id and m.user_id <> p_actor_id and m.member_role = 'adult'
  ) into v_has_partner;

  v_readiness := private.fn_codmon_readiness_v1(v_household_id, v_task.scheduled_date, null);
  -- Missing or duplicated input rows cannot be closed safely; the guard on
  -- codmon_submit reports it below as CODMON_INPUTS_INCOMPLETE.
  if v_readiness->>'state' = 'waiting_inputs' then
    for v_input in
      select value from jsonb_array_elements(coalesce(v_readiness->'inputs', '[]'::jsonb))
    loop
      continue when v_input->>'resolution' <> 'present'
        or coalesce(v_input->>'status', '') not in ('todo', 'in_progress')
        or nullif(v_input->>'task_id', '') is null;
      v_input_task := (v_input->>'task_id')::uuid;
      v_by_partner := v_has_partner and (v_input->>'code') = any(coalesce(p_partner_input_codes, '{}'::text[]));
      -- One derived operation id per input keeps a retried acknowledgement
      -- idempotent: the canonical receipt replays instead of re-completing.
      perform public.server_tx_complete_task(
        p_actor_id,
        md5('codmon-submitted|' || p_operation_id::text || '|' || v_input_task::text)::uuid,
        v_input_task,
        case when v_by_partner then 'partner' else 'self' end,
        true,
        coalesce(p_source, 'pwa')
      );
      v_closed := v_closed + 1;
      if v_by_partner then v_closed_by_partner := v_closed_by_partner + 1; end if;
    end loop;
  end if;

  v_result := public.server_tx_complete_task(
    p_actor_id, p_operation_id, p_submit_task_id, 'self', true, coalesce(p_source, 'pwa'));

  return coalesce(v_result, '{}'::jsonb)
    || jsonb_build_object('task_id', p_submit_task_id, 'inputs_closed', v_closed,
         'inputs_closed_by_partner', v_closed_by_partner);
end;
$$;
revoke all on function public.server_tx_acknowledge_codmon_submission_v1(uuid, uuid, uuid, text, text[])
  from public, anon, authenticated;
grant execute on function public.server_tx_acknowledge_codmon_submission_v1(uuid, uuid, uuid, text, text[])
  to service_role;

create or replace function public.server_tx_end_handover(
  p_actor_id uuid,
  p_operation_id uuid,
  p_handover_id uuid
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_handover public.handovers%rowtype;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_handover_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(sha256(convert_to('end-handover|' || p_handover_id::text, 'UTF8')), 'hex');
  loop
    insert into private.mutation_receipts(actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'end-handover', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id for update;
    if found then
      if v_receipt.request_hash <> v_request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select m.household_id into v_household_id
  from public.household_members m where m.user_id = p_actor_id and m.member_role = 'adult';
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select * into v_handover from public.handovers
  where household_id = v_household_id and id = p_handover_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_handover.test_context_id is not null then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;

  if v_handover.status = 'active' then
    update public.handovers
    set status = 'expired', revision = revision + 1
    where id = v_handover.id;
  end if;

  v_result := jsonb_build_object('ok', true, 'handover_id', p_handover_id, 'status', 'expired');
  update private.mutation_receipts
  set result_type = 'handover', result_id = p_handover_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;
  return v_result;
end;
$$;
revoke all on function public.server_tx_end_handover(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.server_tx_end_handover(uuid, uuid, uuid) to service_role;

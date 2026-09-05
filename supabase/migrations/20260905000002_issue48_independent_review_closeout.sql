-- Issue #48 / PR #50 independent-review remediation.
-- Extend adapters only; canonical aggregates and production side-effect gates
-- remain the source of truth.

-- A one-user test is a synthetic LINE conversation, not a second PWA product.
-- The operator and simulated recipient are still derived by the existing
-- adapter; only the command source records the channel semantics.
create or replace function public.server_tx_test_simulation_send_request_v1(
  p_actor_id uuid, p_test_context_id uuid, p_operation_id uuid, p_direction text,
  p_shared_title text, p_shared_message text default null, p_due_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare c jsonb; v_scope jsonb; v_requester uuid; v_recipient uuid; v_household_id uuid;
begin
  perform private.fn_require_one_user_simulation_p1_v1();
  if p_direction not in ('operator_to_simulated','simulated_to_operator') then raise exception 'TEST_SIMULATION_DIRECTION_INVALID'; end if;
  if length(btrim(coalesce(p_shared_title,''))) > 160 or length(coalesce(p_shared_message,'')) > 2000 then raise exception 'TEST_SIMULATION_REQUEST_INPUT_INVALID'; end if;
  c := private.fn_require_production_actor_context_v1(p_actor_id); v_household_id := (c->>'household_id')::uuid;
  v_scope := private.fn_require_owned_test_simulation_context_v1(v_household_id, p_actor_id, p_test_context_id, true);
  if p_direction = 'operator_to_simulated' then
    v_requester := (v_scope->>'operator_actor_ref_id')::uuid; v_recipient := (v_scope->>'simulated_actor_ref_id')::uuid;
  else
    v_requester := (v_scope->>'simulated_actor_ref_id')::uuid; v_recipient := (v_scope->>'operator_actor_ref_id')::uuid;
  end if;
  return private.fn_command_create_light_request_v1(v_household_id, p_actor_id, v_requester, p_test_context_id, v_recipient, p_shared_title, p_shared_message, p_due_at, p_operation_id, 'line');
end; $$;

create or replace function public.server_tx_test_simulation_respond_request_v1(
  p_actor_id uuid, p_test_context_id uuid, p_operation_id uuid, p_request_id uuid,
  p_attempt_id uuid, p_action text, p_expected_revision bigint, p_expected_terms_revision integer
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare c jsonb; v_scope jsonb; v_request public.requests%rowtype; v_attempt public.request_attempts%rowtype; v_household_id uuid; v_acting_actor uuid;
begin
  perform private.fn_require_one_user_simulation_p1_v1();
  if p_action not in ('accept','decline') then raise exception 'TEST_SIMULATION_REQUEST_ACTION_INVALID'; end if;
  c := private.fn_require_production_actor_context_v1(p_actor_id); v_household_id := (c->>'household_id')::uuid;
  v_scope := private.fn_require_owned_test_simulation_context_v1(v_household_id, p_actor_id, p_test_context_id, true);
  select * into v_request from public.requests r where r.household_id=v_household_id and r.id=p_request_id and r.test_context_id=p_test_context_id;
  if not found then raise exception 'TEST_SIMULATION_REQUEST_NOT_FOUND'; end if;
  if v_request.requester_actor_ref_id not in ((v_scope->>'operator_actor_ref_id')::uuid,(v_scope->>'simulated_actor_ref_id')::uuid)
     or v_request.recipient_actor_ref_id not in ((v_scope->>'operator_actor_ref_id')::uuid,(v_scope->>'simulated_actor_ref_id')::uuid) then raise exception 'TEST_SIMULATION_REQUEST_SCOPE_INVALID'; end if;
  select * into v_attempt from public.request_attempts a where a.household_id=v_household_id and a.id=p_attempt_id and a.request_id=p_request_id and a.test_context_id=p_test_context_id;
  if not found then raise exception 'TEST_SIMULATION_REQUEST_NOT_FOUND'; end if;
  if v_attempt.revision<>p_expected_revision or v_attempt.terms_revision<>p_expected_terms_revision then raise exception 'REQUEST_ATTEMPT_STALE'; end if;
  v_acting_actor := v_request.recipient_actor_ref_id;
  return private.fn_command_transition_request_attempt_v1(v_household_id,p_actor_id,v_acting_actor,p_test_context_id,p_request_id,p_attempt_id,p_action,null,p_expected_revision,p_expected_terms_revision,p_operation_id,'line');
end; $$;

-- Negotiation is intentionally a separate adapter.  The server derives the
-- ActorRef and latest attempt; clients cannot choose either party.  A comment
-- accompanies a decline without changing assignment state.
create or replace function public.server_tx_negotiate_request_v1(
  p_actor_id uuid, p_operation_id uuid, p_request_id uuid, p_attempt_id uuid,
  p_action text, p_terms jsonb default null, p_expected_revision bigint default null,
  p_expected_terms_revision integer default null
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_context jsonb; v_attempt public.request_attempts%rowtype; v_result jsonb;
begin
  if p_action not in ('checking','consult','edit_terms','confirm_terms','decline') then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  select * into v_attempt from public.request_attempts a
    where a.household_id=(v_context->>'household_id')::uuid and a.id=p_attempt_id and a.request_id=p_request_id and a.test_context_id is null for update;
  if not found then raise exception 'REQUEST_ATTEMPT_STALE'; end if;
  v_result := private.fn_command_transition_request_attempt_v1(
    (v_context->>'household_id')::uuid,p_actor_id,(v_context->>'actor_ref_id')::uuid,null,p_request_id,p_attempt_id,p_action,
    case when p_action='decline' then null else p_terms end,
    coalesce(p_expected_revision,v_attempt.revision),coalesce(p_expected_terms_revision,v_attempt.terms_revision),p_operation_id,'pwa');
  if p_action='decline' and coalesce(p_terms->>'comment','')<>'' then
    update public.request_attempts set terms=coalesce(terms,'{}'::jsonb)||jsonb_build_object('decline_comment',p_terms->>'comment') where id=p_attempt_id;
  end if;
  return v_result;
end; $$;

revoke all on function public.server_tx_negotiate_request_v1(uuid,uuid,uuid,uuid,text,jsonb,bigint,integer) from public, anon, authenticated;
grant execute on function public.server_tx_negotiate_request_v1(uuid,uuid,uuid,uuid,text,jsonb,bigint,integer) to service_role;

create or replace function public.server_tx_create_handover_v2(
  p_actor_id uuid, p_operation_id uuid, p_shared_text text, p_period text,
  p_categories text[], p_occurred_on date, p_valid_until timestamptz default null,
  p_ack_policy text default 'none'
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_result jsonb; v_handover_id uuid;
begin
  if p_ack_policy not in ('none','required') or (p_valid_until is not null and p_valid_until < now()) then raise exception 'INVALID_INPUT'; end if;
  v_result := public.server_tx_create_handover(p_actor_id,p_operation_id,p_shared_text,p_period,p_categories,p_occurred_on);
  v_handover_id := (v_result->>'handover_id')::uuid;
  update public.handovers set valid_until=p_valid_until, ack_policy=p_ack_policy, revision=revision+1 where id=v_handover_id;
  return v_result;
end; $$;
revoke all on function public.server_tx_create_handover_v2(uuid,uuid,text,text,text[],date,timestamptz,text) from public, anon, authenticated;
grant execute on function public.server_tx_create_handover_v2(uuid,uuid,text,text,text[],date,timestamptz,text) to service_role;

-- Already-agreed assignment changes should not interrupt a partner for a
-- minor chore. Transport/safety-sensitive work stays immediate; everything
-- else is delivered in the normal digest path.  This runs before the outbox
-- bridge and therefore preserves retry/quota/bundling behavior.
create or replace function private.fn_assignment_change_delivery_urgency_v1(p_task_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case when t.category in ('transport','pickup','dropoff')
                    or coalesce(t.duplicate_sensitivity,'normal') = 'safety_critical'
                    or (t.due_at is not null and t.due_at <= now() + interval '24 hours')
              then 'immediate' else 'digest' end
  from public.task_instances t where t.id=p_task_id
$$;
revoke all on function private.fn_assignment_change_delivery_urgency_v1(uuid) from public, anon, authenticated;

create or replace function private.fn_apply_assignment_change_delivery_policy_v1()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.notification_kind='task.assignment_changed_neutral' and new.aggregate_type='task' and new.aggregate_id is not null then
    new.urgency := private.fn_assignment_change_delivery_urgency_v1(new.aggregate_id);
  end if;
  return new;
end; $$;
revoke all on function private.fn_apply_assignment_change_delivery_policy_v1() from public, anon, authenticated;
drop trigger if exists assignment_change_delivery_policy_v1 on public.user_notifications;
create trigger assignment_change_delivery_policy_v1 before insert on public.user_notifications
for each row execute function private.fn_apply_assignment_change_delivery_policy_v1();

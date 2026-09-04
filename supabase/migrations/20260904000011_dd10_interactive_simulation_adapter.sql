-- DD10 interactive one-user simulation adapter.
--
-- This is intentionally a thin server-side adapter around the already-reviewed
-- canonical test-context commands. The browser never chooses ActorRef ids.
-- Every acting identity is re-derived from the authenticated operator and the
-- operator-owned simulation context. Production delivery/provider side effects
-- remain impossible because all business mutations carry test_context_id.

create or replace function private.fn_require_one_user_simulation_p1_v1()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_enabled boolean;
begin
  select g.release_stage = 'P1'
     and g.reader_enabled
     and g.writer_enabled
     and not g.mutation_paused
    into v_enabled
  from private.canonical_capability_gates g
  where g.capability = 'one_user_simulation_v1';

  if coalesce(v_enabled, false) is not true then
    raise exception 'TEST_SIMULATION_CAPABILITY_NOT_ENABLED';
  end if;
end;
$$;

create or replace function private.fn_require_owned_test_simulation_context_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_test_context_id uuid,
  p_require_active boolean default true
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_context public.test_simulation_contexts%rowtype;
  v_operator_actor_ref_id uuid;
  v_simulated_actor_ref_id uuid;
  v_simulated_role text;
begin
  select * into v_context
  from public.test_simulation_contexts c
  where c.household_id = p_household_id
    and c.id = p_test_context_id;

  if not found then raise exception 'TEST_CONTEXT_NOT_FOUND'; end if;
  if v_context.operator_user_id is distinct from p_operator_user_id then
    raise exception 'TEST_CONTEXT_OPERATOR_MISMATCH';
  end if;
  if p_require_active and v_context.status <> 'active' then
    raise exception 'TEST_CONTEXT_NOT_ACTIVE';
  end if;

  select a.id into v_operator_actor_ref_id
  from public.domain_actor_refs a
  where a.household_id = p_household_id
    and a.actor_kind = 'real_user'
    and a.real_user_id = p_operator_user_id
    and a.test_context_id is null;
  if v_operator_actor_ref_id is null then raise exception 'ACTOR_REF_NOT_FOUND'; end if;

  select a.id, a.simulated_role
    into v_simulated_actor_ref_id, v_simulated_role
  from public.domain_actor_refs a
  where a.household_id = p_household_id
    and a.actor_kind = 'simulated_member'
    and a.test_context_id = p_test_context_id;
  if v_simulated_actor_ref_id is null then raise exception 'SIMULATED_ACTOR_REF_NOT_FOUND'; end if;

  return jsonb_build_object(
    'test_context_id', v_context.id,
    'status', v_context.status,
    'revision', v_context.revision,
    'label', v_context.label,
    'operator_actor_ref_id', v_operator_actor_ref_id,
    'simulated_actor_ref_id', v_simulated_actor_ref_id,
    'simulated_role', v_simulated_role
  );
end;
$$;

create or replace function public.server_tx_get_active_test_simulation_v1(
  p_actor_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c jsonb;
  v_context_id uuid;
  v_scope jsonb;
begin
  perform private.fn_require_one_user_simulation_p1_v1();
  c := private.fn_require_production_actor_context_v1(p_actor_id);

  select s.id into v_context_id
  from public.test_simulation_contexts s
  where s.household_id = (c->>'household_id')::uuid
    and s.operator_user_id = p_actor_id
    and s.status = 'active'
  order by s.created_at desc
  limit 1;

  if v_context_id is null then
    return jsonb_build_object('active', false);
  end if;

  v_scope := private.fn_require_owned_test_simulation_context_v1(
    (c->>'household_id')::uuid, p_actor_id, v_context_id, true
  );

  return v_scope || jsonb_build_object(
    'active', true,
    'operator_display_label', private.fn_actor_display_label_v1(
      (c->>'household_id')::uuid, (v_scope->>'operator_actor_ref_id')::uuid
    ),
    'simulated_display_label', private.fn_actor_display_label_v1(
      (c->>'household_id')::uuid, (v_scope->>'simulated_actor_ref_id')::uuid
    )
  );
end;
$$;

create or replace function public.server_tx_open_test_simulation_interactive_v1(
  p_actor_id uuid,
  p_operation_id uuid,
  p_simulated_role text,
  p_label text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c jsonb;
  v_result jsonb;
begin
  perform private.fn_require_one_user_simulation_p1_v1();
  c := private.fn_require_production_actor_context_v1(p_actor_id);
  v_result := private.fn_command_open_test_simulation_v1(
    (c->>'household_id')::uuid,
    p_actor_id,
    (c->>'actor_ref_id')::uuid,
    p_operation_id,
    p_simulated_role,
    p_label
  );
  return v_result || jsonb_build_object(
    'operator_display_label', private.fn_actor_display_label_v1(
      (c->>'household_id')::uuid, (c->>'actor_ref_id')::uuid
    )
  );
end;
$$;

create or replace function public.server_tx_get_test_simulation_workspace_v2(
  p_actor_id uuid,
  p_test_context_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c jsonb;
  v_scope jsonb;
  v_requests jsonb;
  v_tasks jsonb;
  v_deliveries jsonb;
  v_household_id uuid;
  v_operator_actor_ref_id uuid;
  v_simulated_actor_ref_id uuid;
begin
  perform private.fn_require_one_user_simulation_p1_v1();
  c := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (c->>'household_id')::uuid;
  v_scope := private.fn_require_owned_test_simulation_context_v1(
    v_household_id, p_actor_id, p_test_context_id, false
  );
  v_operator_actor_ref_id := (v_scope->>'operator_actor_ref_id')::uuid;
  v_simulated_actor_ref_id := (v_scope->>'simulated_actor_ref_id')::uuid;

  select coalesce(jsonb_agg(jsonb_build_object(
    'request_id', r.id,
    'title', r.shared_title,
    'message', r.shared_message,
    'due_at', r.due_at,
    'status', r.status,
    'revision', r.revision,
    'direction', case
      when r.requester_actor_ref_id = v_operator_actor_ref_id then 'operator_to_simulated'
      else 'simulated_to_operator'
    end,
    'requester_side', case
      when r.requester_actor_ref_id = v_operator_actor_ref_id then 'operator'
      else 'simulated'
    end,
    'recipient_side', case
      when r.recipient_actor_ref_id = v_operator_actor_ref_id then 'operator'
      else 'simulated'
    end,
    'latest_attempt', case when a.id is null then null else jsonb_build_object(
      'attempt_id', a.id,
      'attempt_kind', a.attempt_kind,
      'state', a.state,
      'revision', a.revision,
      'terms_revision', a.terms_revision,
      'reply_due_at', a.reply_due_at
    ) end,
    'linked_task_id', r.linked_task_instance_id,
    'created_at', r.created_at
  ) order by r.created_at desc), '[]'::jsonb)
  into v_requests
  from public.requests r
  left join lateral (
    select x.*
    from public.request_attempts x
    where x.household_id = r.household_id
      and x.request_id = r.id
      and x.test_context_id = p_test_context_id
    order by x.created_at desc, x.id desc
    limit 1
  ) a on true
  where r.household_id = v_household_id
    and r.test_context_id = p_test_context_id
    and r.requester_actor_ref_id in (v_operator_actor_ref_id, v_simulated_actor_ref_id)
    and r.recipient_actor_ref_id in (v_operator_actor_ref_id, v_simulated_actor_ref_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id', t.id,
    'request_id', r.id,
    'title', t.title,
    'status', t.status,
    'revision', t.revision,
    'due_at', t.due_at,
    'planned_assignee_side', case
      when t.planned_assignee_actor_ref_id = v_operator_actor_ref_id then 'operator'
      when t.planned_assignee_actor_ref_id = v_simulated_actor_ref_id then 'simulated'
      else null
    end,
    'completed_at', t.completed_at
  ) order by t.created_at desc), '[]'::jsonb)
  into v_tasks
  from public.task_instances t
  left join public.requests r
    on r.household_id = t.household_id
   and r.test_context_id = p_test_context_id
   and r.linked_task_instance_id = t.id
  where t.household_id = v_household_id
    and t.test_context_id = p_test_context_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id,
    'semantic_recipient_side', case
      when d.semantic_actor_ref_id = v_operator_actor_ref_id then 'operator'
      when d.semantic_actor_ref_id = v_simulated_actor_ref_id then 'simulated'
      else 'unknown'
    end,
    'channel', d.channel,
    'delivery_mode', d.delivery_mode,
    'status', d.status,
    'payload', d.rendered_payload,
    'created_at', d.created_at
  ) order by d.created_at desc), '[]'::jsonb)
  into v_deliveries
  from private.test_delivery_outbox d
  where d.household_id = v_household_id
    and d.operator_user_id = p_actor_id
    and d.test_context_id = p_test_context_id;

  return jsonb_build_object(
    'test_context_id', p_test_context_id,
    'status', v_scope->>'status',
    'revision', (v_scope->>'revision')::bigint,
    'label', v_scope->'label',
    'simulated_role', v_scope->>'simulated_role',
    'operator_display_label', private.fn_actor_display_label_v1(v_household_id, v_operator_actor_ref_id),
    'simulated_display_label', private.fn_actor_display_label_v1(v_household_id, v_simulated_actor_ref_id),
    'requests', v_requests,
    'tasks', v_tasks,
    'deliveries', v_deliveries,
    'production_side_effects', false
  );
end;
$$;

create or replace function public.server_tx_test_simulation_send_request_v1(
  p_actor_id uuid,
  p_test_context_id uuid,
  p_operation_id uuid,
  p_direction text,
  p_shared_title text,
  p_shared_message text default null,
  p_due_at timestamptz default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c jsonb;
  v_scope jsonb;
  v_requester uuid;
  v_recipient uuid;
  v_household_id uuid;
begin
  perform private.fn_require_one_user_simulation_p1_v1();
  if p_direction not in ('operator_to_simulated','simulated_to_operator') then
    raise exception 'TEST_SIMULATION_DIRECTION_INVALID';
  end if;
  if length(btrim(coalesce(p_shared_title,''))) > 160
     or length(coalesce(p_shared_message,'')) > 2000 then
    raise exception 'TEST_SIMULATION_REQUEST_INPUT_INVALID';
  end if;

  c := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (c->>'household_id')::uuid;
  v_scope := private.fn_require_owned_test_simulation_context_v1(
    v_household_id, p_actor_id, p_test_context_id, true
  );

  if p_direction = 'operator_to_simulated' then
    v_requester := (v_scope->>'operator_actor_ref_id')::uuid;
    v_recipient := (v_scope->>'simulated_actor_ref_id')::uuid;
  else
    v_requester := (v_scope->>'simulated_actor_ref_id')::uuid;
    v_recipient := (v_scope->>'operator_actor_ref_id')::uuid;
  end if;

  return private.fn_command_create_light_request_v1(
    v_household_id,
    p_actor_id,
    v_requester,
    p_test_context_id,
    v_recipient,
    p_shared_title,
    p_shared_message,
    p_due_at,
    p_operation_id,
    'pwa'
  );
end;
$$;

create or replace function public.server_tx_test_simulation_respond_request_v1(
  p_actor_id uuid,
  p_test_context_id uuid,
  p_operation_id uuid,
  p_request_id uuid,
  p_attempt_id uuid,
  p_action text,
  p_expected_revision bigint,
  p_expected_terms_revision integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c jsonb;
  v_scope jsonb;
  v_request public.requests%rowtype;
  v_attempt public.request_attempts%rowtype;
  v_household_id uuid;
  v_acting_actor uuid;
begin
  perform private.fn_require_one_user_simulation_p1_v1();
  if p_action not in ('accept','decline') then
    raise exception 'TEST_SIMULATION_REQUEST_ACTION_INVALID';
  end if;

  c := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (c->>'household_id')::uuid;
  v_scope := private.fn_require_owned_test_simulation_context_v1(
    v_household_id, p_actor_id, p_test_context_id, true
  );

  select * into v_request
  from public.requests r
  where r.household_id = v_household_id
    and r.id = p_request_id
    and r.test_context_id = p_test_context_id;
  if not found then raise exception 'TEST_SIMULATION_REQUEST_NOT_FOUND'; end if;

  if v_request.requester_actor_ref_id not in (
       (v_scope->>'operator_actor_ref_id')::uuid,
       (v_scope->>'simulated_actor_ref_id')::uuid
     )
     or v_request.recipient_actor_ref_id not in (
       (v_scope->>'operator_actor_ref_id')::uuid,
       (v_scope->>'simulated_actor_ref_id')::uuid
     ) then
    raise exception 'TEST_SIMULATION_REQUEST_SCOPE_INVALID';
  end if;

  select * into v_attempt
  from public.request_attempts a
  where a.household_id = v_household_id
    and a.id = p_attempt_id
    and a.request_id = p_request_id
    and a.test_context_id = p_test_context_id;
  if not found then raise exception 'TEST_SIMULATION_REQUEST_NOT_FOUND'; end if;
  if v_attempt.revision <> p_expected_revision
     or v_attempt.terms_revision <> p_expected_terms_revision then
    raise exception 'REQUEST_ATTEMPT_STALE';
  end if;

  -- Only the request recipient can answer. The actor is derived from the row;
  -- the browser never supplies or chooses an ActorRef id.
  v_acting_actor := v_request.recipient_actor_ref_id;

  return private.fn_command_transition_request_attempt_v1(
    v_household_id,
    p_actor_id,
    v_acting_actor,
    p_test_context_id,
    p_request_id,
    p_attempt_id,
    p_action,
    null,
    p_expected_revision,
    p_expected_terms_revision,
    p_operation_id,
    'pwa'
  );
end;
$$;

create or replace function public.server_tx_test_simulation_complete_task_v1(
  p_actor_id uuid,
  p_test_context_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_expected_revision bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c jsonb;
  v_scope jsonb;
  v_task public.task_instances%rowtype;
  v_household_id uuid;
  v_acting_actor uuid;
begin
  perform private.fn_require_one_user_simulation_p1_v1();
  c := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (c->>'household_id')::uuid;
  v_scope := private.fn_require_owned_test_simulation_context_v1(
    v_household_id, p_actor_id, p_test_context_id, true
  );

  select * into v_task
  from public.task_instances t
  where t.household_id = v_household_id
    and t.id = p_task_id
    and t.test_context_id = p_test_context_id;
  if not found then raise exception 'TEST_SIMULATION_TASK_NOT_FOUND'; end if;
  if v_task.revision <> p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;

  v_acting_actor := v_task.planned_assignee_actor_ref_id;
  if v_acting_actor is null
     or v_acting_actor not in (
       (v_scope->>'operator_actor_ref_id')::uuid,
       (v_scope->>'simulated_actor_ref_id')::uuid
     ) then
    raise exception 'TEST_SIMULATION_TASK_SCOPE_INVALID';
  end if;

  return private.fn_command_complete_task_v1(
    v_household_id,
    p_actor_id,
    v_acting_actor,
    p_test_context_id,
    p_task_id,
    array[v_acting_actor]::uuid[],
    p_expected_revision,
    p_operation_id,
    'pwa'
  );
end;
$$;

create or replace function public.server_tx_archive_test_simulation_interactive_v1(
  p_actor_id uuid,
  p_operation_id uuid,
  p_test_context_id uuid,
  p_expected_revision bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c jsonb;
  v_scope jsonb;
begin
  perform private.fn_require_one_user_simulation_p1_v1();
  c := private.fn_require_production_actor_context_v1(p_actor_id);
  v_scope := private.fn_require_owned_test_simulation_context_v1(
    (c->>'household_id')::uuid, p_actor_id, p_test_context_id, true
  );
  if (v_scope->>'revision')::bigint <> p_expected_revision then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;

  return private.fn_command_archive_test_simulation_v1(
    (c->>'household_id')::uuid,
    p_actor_id,
    (c->>'actor_ref_id')::uuid,
    p_test_context_id,
    p_expected_revision,
    p_operation_id
  );
end;
$$;

revoke all on function private.fn_require_one_user_simulation_p1_v1() from public, anon, authenticated;
revoke all on function private.fn_require_owned_test_simulation_context_v1(uuid,uuid,uuid,boolean) from public, anon, authenticated;
grant execute on function private.fn_require_one_user_simulation_p1_v1() to service_role;
grant execute on function private.fn_require_owned_test_simulation_context_v1(uuid,uuid,uuid,boolean) to service_role;

revoke all on function public.server_tx_get_active_test_simulation_v1(uuid) from public, anon, authenticated;
revoke all on function public.server_tx_open_test_simulation_interactive_v1(uuid,uuid,text,text) from public, anon, authenticated;
revoke all on function public.server_tx_get_test_simulation_workspace_v2(uuid,uuid) from public, anon, authenticated;
revoke all on function public.server_tx_test_simulation_send_request_v1(uuid,uuid,uuid,text,text,text,timestamptz) from public, anon, authenticated;
revoke all on function public.server_tx_test_simulation_respond_request_v1(uuid,uuid,uuid,uuid,uuid,text,bigint,integer) from public, anon, authenticated;
revoke all on function public.server_tx_test_simulation_complete_task_v1(uuid,uuid,uuid,uuid,bigint) from public, anon, authenticated;
revoke all on function public.server_tx_archive_test_simulation_interactive_v1(uuid,uuid,uuid,bigint) from public, anon, authenticated;

grant execute on function public.server_tx_get_active_test_simulation_v1(uuid) to service_role;
grant execute on function public.server_tx_open_test_simulation_interactive_v1(uuid,uuid,text,text) to service_role;
grant execute on function public.server_tx_get_test_simulation_workspace_v2(uuid,uuid) to service_role;
grant execute on function public.server_tx_test_simulation_send_request_v1(uuid,uuid,uuid,text,text,text,timestamptz) to service_role;
grant execute on function public.server_tx_test_simulation_respond_request_v1(uuid,uuid,uuid,uuid,uuid,text,bigint,integer) to service_role;
grant execute on function public.server_tx_test_simulation_complete_task_v1(uuid,uuid,uuid,uuid,bigint) to service_role;
grant execute on function public.server_tx_archive_test_simulation_interactive_v1(uuid,uuid,uuid,bigint) to service_role;

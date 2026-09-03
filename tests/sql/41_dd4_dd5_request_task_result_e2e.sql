-- WP-DD4 / WP-DD5 canonical E2E using only WP-DD3-owned command signatures:
-- create light Request -> accept -> linked Task -> complete -> actual/history.
\set ON_ERROR_STOP on

set role service_role;
do $$
declare
  v_requester uuid := gen_random_uuid();
  v_recipient uuid := gen_random_uuid();
  v_hh jsonb;
  v_hh_id uuid;
  v_requester_actor uuid;
  v_recipient_actor uuid;
  v_create jsonb;
  v_accept jsonb;
  v_complete jsonb;
  v_request_id uuid;
  v_attempt_id uuid;
  v_task_id uuid;
  v_workspace jsonb;
  v_history jsonb;
  v_item jsonb;
begin
  insert into auth.users (id) values (v_requester), (v_recipient);

  v_hh := public.server_tx_create_household(
    v_requester, gen_random_uuid(), 'DD4 DD5 E2E ' || v_requester::text, 'Requester'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, v_recipient, 'adult');

  -- R0 helper creates the production ActorRefs used by canonical commands.
  perform private.backfill_canonical_foundation_v1();

  select id into v_requester_actor from public.domain_actor_refs
  where household_id = v_hh_id and actor_kind = 'real_user' and real_user_id = v_requester;
  select id into v_recipient_actor from public.domain_actor_refs
  where household_id = v_hh_id and actor_kind = 'real_user' and real_user_id = v_recipient;
  if v_requester_actor is null or v_recipient_actor is null then
    raise exception 'FAIL dd4-dd5-e2e: ActorRef setup failed';
  end if;

  v_create := private.fn_command_create_light_request_v1(
    v_hh_id, v_requester, v_requester_actor, null, v_recipient_actor,
    '明日の準備をお願い', '水着セットをお願いします',
    now() + interval '1 day', gen_random_uuid(), 'pwa'
  );
  v_request_id := (v_create->>'request_id')::uuid;
  v_attempt_id := (v_create->>'attempt_id')::uuid;

  if v_request_id is null or v_attempt_id is null or v_create->>'state' <> 'pending' then
    raise exception 'FAIL dd4-dd5-e2e: Request create result invalid: %', v_create;
  end if;
  if (select linked_task_instance_id from public.requests where id = v_request_id) is not null then
    raise exception 'FAIL dd4-dd5-e2e: Task existed before agreement';
  end if;

  v_accept := private.fn_command_transition_request_attempt_v1(
    v_hh_id, v_recipient, v_recipient_actor, null,
    v_request_id, v_attempt_id, 'accept', '{}'::jsonb,
    1, 1, gen_random_uuid(), 'pwa'
  );
  v_task_id := (v_accept->>'linked_task_id')::uuid;

  if v_accept->>'state' <> 'accepted' or v_task_id is null then
    raise exception 'FAIL dd4-dd5-e2e: accept did not create linked Task: %', v_accept;
  end if;
  if (select linked_task_instance_id from public.requests where id = v_request_id) <> v_task_id then
    raise exception 'FAIL dd4-dd5-e2e: Request linked Task mismatch';
  end if;
  if not exists (
    select 1 from public.task_instances
    where id = v_task_id and household_id = v_hh_id
      and status = 'todo'
      and assignment_mode = 'person'
      and assignment_source = 'agreement'
      and planned_assignee_actor_ref_id = v_recipient_actor
  ) then
    raise exception 'FAIL dd4-dd5-e2e: accepted agreement Task snapshot invalid';
  end if;

  v_complete := private.fn_command_complete_task_v1(
    v_hh_id, v_recipient, v_recipient_actor, null,
    v_task_id, array[v_recipient_actor], 1, gen_random_uuid(), 'pwa'
  );
  if v_complete->>'status' <> 'completed' then
    raise exception 'FAIL dd4-dd5-e2e: Task completion failed: %', v_complete;
  end if;

  if not exists (
    select 1 from public.task_actual_participants
    where household_id = v_hh_id and task_instance_id = v_task_id
      and actor_ref_id = v_recipient_actor and removed_at is null
      and compatibility_primary
  ) then
    raise exception 'FAIL dd4-dd5-e2e: canonical actual performer missing';
  end if;
  if (select count(*) from public.task_actual_participants where task_instance_id = v_task_id and removed_at is null) <> 1 then
    raise exception 'FAIL dd4-dd5-e2e: completion produced unexpected performer count';
  end if;

  v_workspace := public.server_read_request_workspace(v_requester);
  select value into v_item
  from jsonb_array_elements(v_workspace->'outgoing') x(value)
  where value->>'request_id' = v_request_id::text;
  if v_item is null
     or v_item->>'coordination_state' <> 'agreed'
     or coalesce(v_item#>>'{execution,status}', '') <> 'completed'
     or coalesce(v_item#>>'{agreement,attempt_id}', '') <> v_attempt_id::text then
    raise exception 'FAIL dd4-dd5-e2e: Request workspace lost agreement/execution separation: %', v_item;
  end if;

  v_history := public.server_read_task_result_history(v_requester, current_date - 1);
  select value into v_item
  from jsonb_array_elements(v_history->'items') x(value)
  where value->>'task_id' = v_task_id::text;
  if v_item is null
     or v_item->>'semantic_result' <> 'completed'
     or (v_item->>'performer_count')::int <> 1
     or (v_item->>'household_completion_units')::int <> 1 then
    raise exception 'FAIL dd4-dd5-e2e: result history invalid: %', v_item;
  end if;
  if coalesce(v_item#>>'{performers,0,actor_ref_id}', '') <> v_recipient_actor::text then
    raise exception 'FAIL dd4-dd5-e2e: actual performer identity missing from history: %', v_item;
  end if;

  -- Request completion is not independently inferred. Execution remains the
  -- linked Task's state while the accepted agreement remains durable evidence.
  if (select status from public.requests where id = v_request_id) <> 'accepted' then
    raise exception 'FAIL dd4-dd5-e2e: Task completion rewrote Request agreement lifecycle';
  end if;
end;
$$;

reset role;
select 'dd4_dd5_request_task_result_e2e: PASS' as result;

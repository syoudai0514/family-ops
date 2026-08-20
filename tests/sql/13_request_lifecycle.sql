-- WP2: request lifecycle — send/accept/decline/cancel.
-- docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md request section.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('b0000000-0000-0000-0000-000000000001'), -- requester
  ('b0000000-0000-0000-0000-000000000002'); -- recipient

set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_request_id uuid;
  v_task_id uuid;
  v_result jsonb;
begin
  v_hh := public.server_tx_create_household('b0000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Request Lifecycle HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, 'b0000000-0000-0000-0000-000000000002', 'adult');

  -- send-request: self-recipient rejected
  begin
    perform public.server_tx_send_request(
      'b0000000-0000-0000-0000-000000000001', gen_random_uuid(), 'b0000000-0000-0000-0000-000000000001', 'x', null, null
    );
    raise exception 'FAIL request-lifecycle: sending a request to yourself must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL request-lifecycle: expected INVALID_INPUT, got %', sqlerrm;
      end if;
  end;

  -- send-request happy path
  v_result := public.server_tx_send_request(
    'b0000000-0000-0000-0000-000000000001', gen_random_uuid(), 'b0000000-0000-0000-0000-000000000002',
    'Pick up dry cleaning', 'before 6pm please', null
  );
  v_request_id := (v_result->>'request_id')::uuid;
  if (select status from public.requests where id = v_request_id) <> 'pending' then
    raise exception 'FAIL request-lifecycle: send-request must create a pending request';
  end if;
  if not exists (
    select 1 from public.user_notifications
    where household_id = v_hh_id and recipient_user_id = 'b0000000-0000-0000-0000-000000000002' and type = 'request_received'
  ) then
    raise exception 'FAIL request-lifecycle: send-request must notify the recipient';
  end if;

  -- decline requires being the recipient
  begin
    perform public.server_tx_decline_request('b0000000-0000-0000-0000-000000000001', gen_random_uuid(), v_request_id);
    raise exception 'FAIL request-lifecycle: decline by the requester (not recipient) must be rejected';
  exception
    when others then
      if sqlerrm <> 'REQUEST_NOT_RECIPIENT' then
        raise exception 'FAIL request-lifecycle: expected REQUEST_NOT_RECIPIENT, got %', sqlerrm;
      end if;
  end;

  -- accept-request: creates a linked task
  v_result := public.server_tx_accept_request('b0000000-0000-0000-0000-000000000002', gen_random_uuid(), v_request_id);
  v_task_id := (v_result->>'task_id')::uuid;
  if v_task_id is null then
    raise exception 'FAIL request-lifecycle: accept-request must return a task_id';
  end if;
  if (select status from public.requests where id = v_request_id) <> 'accepted' then
    raise exception 'FAIL request-lifecycle: accept-request must set status=accepted';
  end if;
  if (select linked_task_instance_id from public.requests where id = v_request_id) <> v_task_id then
    raise exception 'FAIL request-lifecycle: linked_task_instance_id must equal the created task';
  end if;
  if (select origin from public.task_instances where id = v_task_id) <> 'request' then
    raise exception 'FAIL request-lifecycle: linked task must have origin=request';
  end if;

  -- re-accepting an already-accepted request (different actor call, not a
  -- replay) is rejected, not silently treated as idempotent
  begin
    perform public.server_tx_accept_request('b0000000-0000-0000-0000-000000000002', gen_random_uuid(), v_request_id);
    raise exception 'FAIL request-lifecycle: accepting an already-accepted request must be rejected';
  exception
    when others then
      if sqlerrm <> 'REQUEST_NOT_PENDING' then
        raise exception 'FAIL request-lifecycle: expected REQUEST_NOT_PENDING, got %', sqlerrm;
      end if;
  end;

  -- pending-only cancel: an accepted request can never be cancelled
  begin
    perform public.server_tx_cancel_request('b0000000-0000-0000-0000-000000000001', gen_random_uuid(), v_request_id);
    raise exception 'FAIL request-lifecycle: cancelling an accepted request must be rejected';
  exception
    when others then
      if sqlerrm <> 'REQUEST_CANCEL_NOT_ALLOWED' then
        raise exception 'FAIL request-lifecycle: expected REQUEST_CANCEL_NOT_ALLOWED, got %', sqlerrm;
      end if;
  end;

  -- completing the linked task completes the accepted request too
  perform public.server_tx_complete_task('b0000000-0000-0000-0000-000000000002', gen_random_uuid(), v_task_id, 'self', null);
  if (select status from public.requests where id = v_request_id) <> 'completed' then
    raise exception 'FAIL request-lifecycle: completing the linked task must complete the accepted request';
  end if;
end;
$$;

-- decline path
do $$
declare
  v_hh_id uuid;
  v_request_id uuid;
  v_result jsonb;
begin
  select id into v_hh_id from public.households where name = 'Request Lifecycle HH';

  v_result := public.server_tx_send_request(
    'b0000000-0000-0000-0000-000000000001', gen_random_uuid(), 'b0000000-0000-0000-0000-000000000002', 'Buy milk', null, null
  );
  v_request_id := (v_result->>'request_id')::uuid;

  perform public.server_tx_decline_request('b0000000-0000-0000-0000-000000000002', gen_random_uuid(), v_request_id);
  if (select status from public.requests where id = v_request_id) <> 'declined' then
    raise exception 'FAIL request-lifecycle: decline-request must set status=declined';
  end if;
  if exists (select 1 from public.task_instances where household_id = v_hh_id and title = 'Buy milk') then
    raise exception 'FAIL request-lifecycle: a declined request must never create a task';
  end if;
end;
$$;

-- cancel path (requester, still pending)
do $$
declare
  v_hh_id uuid;
  v_request_id uuid;
  v_result jsonb;
begin
  select id into v_hh_id from public.households where name = 'Request Lifecycle HH';

  v_result := public.server_tx_send_request(
    'b0000000-0000-0000-0000-000000000001', gen_random_uuid(), 'b0000000-0000-0000-0000-000000000002', 'Water plants', null, null
  );
  v_request_id := (v_result->>'request_id')::uuid;

  -- cancel by the recipient (not requester) is rejected
  begin
    perform public.server_tx_cancel_request('b0000000-0000-0000-0000-000000000002', gen_random_uuid(), v_request_id);
    raise exception 'FAIL request-lifecycle: cancel by the recipient (not requester) must be rejected';
  exception
    when others then
      if sqlerrm <> 'REQUEST_NOT_REQUESTER' then
        raise exception 'FAIL request-lifecycle: expected REQUEST_NOT_REQUESTER, got %', sqlerrm;
      end if;
  end;

  perform public.server_tx_cancel_request('b0000000-0000-0000-0000-000000000001', gen_random_uuid(), v_request_id);
  if (select status from public.requests where id = v_request_id) <> 'cancelled' then
    raise exception 'FAIL request-lifecycle: cancel-request must set status=cancelled';
  end if;
end;
$$;

reset role;
select 'request_lifecycle: PASS' as result;

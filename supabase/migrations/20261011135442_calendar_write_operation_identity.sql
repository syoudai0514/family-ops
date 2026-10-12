-- Each operation has its own idempotency receipt. A provider event can be
-- created and then updated repeatedly, so its identity must not be unique
-- across the operation ledger. Keep the event lookup index non-unique.
alter table private.google_write_operations
  drop constraint google_write_operations_calendar_connection_id_google_event_key;

create index google_write_operations_calendar_event_idx
  on private.google_write_operations (calendar_connection_id, google_event_id);

create or replace function public.server_tx_claim_google_write(
  p_actor_id uuid,
  p_operation_id uuid,
  p_calendar_connection_id uuid,
  p_action text,
  p_request_hash text,
  p_target_google_event_id text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_google_event_id text;
  v_row record;
begin
  if p_actor_id is null or p_operation_id is null or p_calendar_connection_id is null
     or p_action is null or p_request_hash is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_action not in ('create', 'update') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_action = 'update' and (p_target_google_event_id is null or length(p_target_google_event_id) = 0) then
    raise exception 'INVALID_INPUT';
  end if;
  if p_action = 'create' and p_target_google_event_id is not null then
    raise exception 'INVALID_INPUT';
  end if;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;
  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;
  if not exists (
    select 1 from public.calendar_connections
    where id = p_calendar_connection_id and household_id = v_household_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  v_google_event_id := case
    when p_action = 'create' then private.google_deterministic_event_id(p_operation_id)
    else p_target_google_event_id
  end;

  insert into private.google_write_operations (
    operation_id, household_id, calendar_connection_id, google_event_id, action, request_hash, status
  ) values (
    p_operation_id, v_household_id, p_calendar_connection_id, v_google_event_id, p_action, p_request_hash, 'pending'
  )
  on conflict (operation_id) do nothing;

  select * into v_row
  from private.google_write_operations
  where operation_id = p_operation_id
  for update;

  if v_row.request_hash <> p_request_hash
     or v_row.household_id <> v_household_id
     or v_row.calendar_connection_id <> p_calendar_connection_id
     or v_row.google_event_id <> v_google_event_id
     or v_row.action <> p_action then
    raise exception 'IDEMPOTENCY_CONFLICT';
  end if;

  return jsonb_build_object(
    'google_event_id', v_row.google_event_id,
    'status', v_row.status,
    'result_etag', v_row.result_etag,
    'action', v_row.action
  );
end;
$$;

-- UX v2: A request to take over an existing task is not a new task.  The
-- accepting partner becomes the canonical planned assignee of that exact
-- instance, atomically and idempotently.

alter table public.requests
  add column assignment_task_instance_id uuid null,
  add column assignment_scope text null check (assignment_scope in ('once', 'this_week')),
  add foreign key (household_id, assignment_task_instance_id)
    references public.task_instances (household_id, id);

create index requests_assignment_task_instance_idx
  on public.requests (household_id, assignment_task_instance_id)
  where assignment_task_instance_id is not null;

create table public.assignment_change_request_tasks (
  request_id uuid not null references public.requests (id) on delete cascade,
  household_id uuid not null references public.households (id),
  task_instance_id uuid not null,
  primary key (request_id, task_instance_id),
  foreign key (household_id, task_instance_id) references public.task_instances (household_id, id)
);
alter table public.assignment_change_request_tasks enable row level security;

create or replace function public.server_tx_create_assignment_change_request(
  p_actor_id uuid, p_operation_id uuid, p_task_id uuid, p_recipient_user_id uuid,
  p_shared_message text, p_scope text
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_household_id uuid; v_task public.task_instances%rowtype; v_receipt record;
  v_hash text; v_request_id uuid; v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null or p_recipient_user_id is null
     or p_recipient_user_id = p_actor_id or p_scope not in ('once', 'this_week') then raise exception 'INVALID_INPUT'; end if;
  v_hash := encode(sha256(convert_to('assignment-change|' || p_task_id::text || '|' || p_recipient_user_id::text || '|' || p_scope, 'UTF8')), 'hex');
  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
      values (p_actor_id, p_operation_id, 'assignment-change-request', v_hash) on conflict (actor_id, operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts where actor_id = p_actor_id and operation_id = p_operation_id for update;
    if v_receipt.request_hash <> v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result_payload;
  end loop;
  select household_id into v_household_id from public.household_members where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  if not exists (select 1 from public.household_members where household_id = v_household_id and user_id = p_recipient_user_id) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  select * into v_task from public.task_instances where household_id = v_household_id and id = p_task_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_task.planned_assignee_id <> p_actor_id or v_task.status not in ('todo', 'in_progress') then raise exception 'ASSIGNMENT_CHANGE_NOT_ALLOWED'; end if;
  insert into public.requests (household_id, requester_id, recipient_id, shared_title, shared_message, due_at, status, assignment_task_instance_id, assignment_scope)
    values (v_household_id, p_actor_id, p_recipient_user_id, v_task.title, nullif(btrim(coalesce(p_shared_message, '')), ''), v_task.due_at, 'pending', p_task_id, p_scope)
    returning id into v_request_id;
  -- “今週だけ” is one decision, not seven independent asks.  It includes
  -- the same recurring definition through Sunday; a one-off task remains one.
  insert into public.assignment_change_request_tasks (request_id, household_id, task_instance_id)
    select v_request_id, v_household_id, candidate.id
    from public.task_instances candidate
    where candidate.household_id = v_household_id
      and candidate.status in ('todo', 'in_progress')
      and (candidate.id = p_task_id or (
        p_scope = 'this_week' and candidate.task_definition_id is not null
        and candidate.task_definition_id = v_task.task_definition_id
        and candidate.planned_assignee_id = p_actor_id
        and candidate.scheduled_date between v_task.scheduled_date
          and (v_task.scheduled_date + (7 - extract(isodow from v_task.scheduled_date)::int))
      ));
  insert into public.user_notifications (household_id, recipient_user_id, type, title, body, payload, dedup_key)
    values (v_household_id, p_recipient_user_id, 'request_received', v_task.title,
      coalesce(nullif(btrim(p_shared_message), ''), '担当変更のお願いです。'),
      jsonb_build_object('request_id', v_request_id, 'request_kind', 'assignment_change', 'task_instance_id', p_task_id, 'scope', p_scope),
      p_operation_id::text || ':assignment_change_received');
  v_result := jsonb_build_object('request_id', v_request_id, 'task_id', p_task_id);
  update private.mutation_receipts set result_type = 'request', result_id = v_request_id, result_payload = v_result where actor_id = p_actor_id and operation_id = p_operation_id;
  return v_result;
end; $$;

create or replace function public.server_tx_accept_assignment_change_request(
  p_actor_id uuid, p_operation_id uuid, p_request_id uuid
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_household_id uuid; v_request public.requests%rowtype; v_task public.task_instances%rowtype;
  v_receipt record; v_hash text; v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_request_id is null then raise exception 'INVALID_INPUT'; end if;
  v_hash := encode(sha256(convert_to('accept-assignment-change|' || p_request_id::text, 'UTF8')), 'hex');
  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
      values (p_actor_id, p_operation_id, 'accept-assignment-change', v_hash) on conflict (actor_id, operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts where actor_id = p_actor_id and operation_id = p_operation_id for update;
    if v_receipt.request_hash <> v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result_payload;
  end loop;
  select household_id into v_household_id from public.household_members where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select * into v_request from public.requests where household_id = v_household_id and id = p_request_id for update;
  if not found or v_request.recipient_id <> p_actor_id or v_request.status <> 'pending' or v_request.assignment_task_instance_id is null then raise exception 'REQUEST_NOT_PENDING'; end if;
  select * into v_task from public.task_instances where household_id = v_household_id and id = v_request.assignment_task_instance_id for update;
  if not found or v_task.status not in ('todo', 'in_progress') then raise exception 'TASK_TERMINAL'; end if;
  update public.task_instances set planned_assignee_id = p_actor_id where household_id = v_household_id and id = v_task.id;
  update public.task_instances set planned_assignee_id = p_actor_id
    where household_id = v_household_id and id in (
      select task_instance_id from public.assignment_change_request_tasks where request_id = v_request.id
    ) and status in ('todo', 'in_progress');
  update public.requests set status = 'accepted', accepted_at = now(), linked_task_instance_id = v_task.id where household_id = v_household_id and id = v_request.id;
  insert into public.task_events (household_id, task_instance_id, actor_id, event_type, payload, source, idempotency_key)
    values (v_household_id, v_task.id, p_actor_id, 'reassigned_once', jsonb_build_object('from', v_task.planned_assignee_id, 'to', p_actor_id, 'request_id', v_request.id), 'request', p_operation_id::text);
  insert into public.user_notifications (household_id, recipient_user_id, type, title, body, payload, dedup_key)
    values (v_household_id, v_request.requester_id, 'request_accepted', v_request.shared_title, '引き受けてもらいました。', jsonb_build_object('request_id', v_request.id, 'request_kind', 'assignment_change'), p_operation_id::text || ':assignment_change_accepted');
  v_result := jsonb_build_object('request_id', v_request.id, 'task_id', v_task.id, 'new_assignee_user_id', p_actor_id);
  update private.mutation_receipts set result_type = 'request', result_id = v_request.id, result_payload = v_result where actor_id = p_actor_id and operation_id = p_operation_id;
  return v_result;
end; $$;

revoke all on function public.server_tx_create_assignment_change_request(uuid, uuid, uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.server_tx_accept_assignment_change_request(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.server_tx_create_assignment_change_request(uuid, uuid, uuid, uuid, text, text) to service_role;
grant execute on function public.server_tx_accept_assignment_change_request(uuid, uuid, uuid) to service_role;

-- The existing outbox bridge intentionally sends only a compact notification
-- envelope.  Add the canonical request payload afterwards, keyed by the
-- notification ID, so the LINE worker can build a Flex card without exposing
-- any private raw input.
create or replace function private.fn_enrich_line_outbox_request_payload()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if new.type <> 'request_received' or coalesce(new.payload->>'request_kind', '') <> 'assignment_change' then return new; end if;
  update private.notification_outbox o
  set payload = jsonb_set(o.payload, '{items}', (
    select jsonb_agg(case when item->>'user_notification_id' = new.id::text then item || jsonb_build_object('payload', new.payload) else item end)
    from jsonb_array_elements(coalesce(o.payload->'items', '[]'::jsonb)) item
  ))
  where o.household_id = new.household_id and o.recipient_user_id = new.recipient_user_id and o.status = 'queued'
    and o.payload @> jsonb_build_object('items', jsonb_build_array(jsonb_build_object('user_notification_id', new.id)));
  return new;
end; $$;
create trigger zz_enrich_line_outbox_request_payload after insert on public.user_notifications
  for each row execute function private.fn_enrich_line_outbox_request_payload();

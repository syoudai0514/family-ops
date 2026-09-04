-- Independent source-review remediation:
-- - completed Request history is terminal and cannot be rolled back by a later
--   follow-up projection;
-- - CURRENT handover_reads and canonical info_acknowledgements stay compatible;
-- - authenticated canonical read adapters obey the R0/P1 capability gate.
-- No capability is advanced and no external side effect is activated here.

-- ---------------------------------------------------------------------------
-- HIGH-2: completion is execution history, not a negotiable Attempt state.
-- Keep the existing projector intact behind a small terminal-state fence.
-- ---------------------------------------------------------------------------

alter function private.fn_project_request_legacy_lifecycle_v1(uuid, uuid)
  rename to fn_project_request_legacy_lifecycle_v1_pre_completion_fence;

create or replace function private.fn_project_request_legacy_lifecycle_v1(
  p_household_id uuid,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.requests%rowtype;
  v_task public.task_instances%rowtype;
  v_completed_at timestamptz;
begin
  select * into v_request
  from public.requests
  where household_id = p_household_id and id = p_request_id
  for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;

  -- Once completion was recorded, negotiation/follow-up projection may never
  -- erase that fact or its timestamp, regardless of Attempt origin.
  if v_request.status = 'completed' then
    return jsonb_build_object(
      'status', v_request.status,
      'accepted_at', v_request.accepted_at,
      'declined_at', v_request.declined_at,
      'cancelled_at', v_request.cancelled_at,
      'completed_at', v_request.completed_at,
      'preserved_completed', true
    );
  end if;

  -- Defense in depth for a CURRENT/legacy completion writer racing a pending
  -- follow-up: the linked Task execution truth wins before Attempt projection.
  if v_request.linked_task_instance_id is not null then
    select * into v_task
    from public.task_instances t
    where t.household_id = p_household_id
      and t.id = v_request.linked_task_instance_id;

    if found and v_task.status = 'completed' then
      if v_request.status <> 'accepted' or v_request.accepted_at is null then
        raise exception 'REQUEST_TASK_LIFECYCLE_CONFLICT';
      end if;
      v_completed_at := coalesce(v_request.completed_at, v_task.completed_at, now());
      update public.requests
      set status = 'completed',
          completed_at = v_completed_at,
          declined_at = null,
          cancelled_at = null,
          revision = revision + 1
      where household_id = p_household_id and id = p_request_id;
      return jsonb_build_object(
        'status', 'completed',
        'accepted_at', v_request.accepted_at,
        'declined_at', null,
        'cancelled_at', null,
        'completed_at', v_completed_at,
        'preserved_task_completion', true
      );
    end if;
  end if;

  return private.fn_project_request_legacy_lifecycle_v1_pre_completion_fence(
    p_household_id, p_request_id
  );
end;
$$;
revoke all on function private.fn_project_request_legacy_lifecycle_v1(uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.fn_project_request_legacy_lifecycle_v1(uuid, uuid)
  to service_role;

-- ---------------------------------------------------------------------------
-- HIGH-3: migration bridge for the established mark-read path.  Existing
-- production handover_reads are backfilled once; future CURRENT writes persist
-- the ActorRef acknowledgement in the same transaction.  This is DB-only and
-- does not send LINE/browser/provider traffic.
-- ---------------------------------------------------------------------------

insert into public.info_acknowledgements(
  household_id, handover_id, actor_ref_id, acknowledged_at, test_context_id
)
select hr.household_id, hr.handover_id, a.id, hr.read_at, null
from public.handover_reads hr
join public.handovers h
  on h.household_id = hr.household_id and h.id = hr.handover_id
join public.domain_actor_refs a
  on a.household_id = hr.household_id
 and a.actor_kind = 'real_user'
 and a.real_user_id = hr.user_id
where h.test_context_id is null
on conflict (handover_id, actor_ref_id) do nothing;

create or replace function public.server_tx_mark_handover_read(
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
  v_actor_ref_id uuid;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_handover_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to('mark-handover-read|' || p_handover_id::text, 'UTF8')),
    'hex'
  );

  loop
    insert into private.mutation_receipts(actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'mark-handover-read', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;

    if found then exit; end if;

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

  select m.household_id, a.id
    into v_household_id, v_actor_ref_id
  from public.household_members m
  join public.domain_actor_refs a
    on a.household_id = m.household_id
   and a.actor_kind = 'real_user'
   and a.real_user_id = m.user_id
  where m.user_id = p_actor_id;

  if v_household_id is null or v_actor_ref_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  if not exists (
    select 1 from public.handovers h
    where h.household_id = v_household_id
      and h.id = p_handover_id
      and h.test_context_id is null
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  insert into public.handover_reads(household_id, handover_id, user_id, read_at)
  values (v_household_id, p_handover_id, p_actor_id, now())
  on conflict (handover_id, user_id) do nothing;

  insert into public.info_acknowledgements(
    household_id, handover_id, actor_ref_id, acknowledged_at, test_context_id
  ) values (
    v_household_id, p_handover_id, v_actor_ref_id, now(), null
  ) on conflict (handover_id, actor_ref_id) do nothing;

  v_result := jsonb_build_object('ok', true);
  update private.mutation_receipts
  set result_type = 'handover',
      result_id = p_handover_id,
      result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;
revoke all on function public.server_tx_mark_handover_read(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.server_tx_mark_handover_read(uuid, uuid, uuid)
  to service_role;

-- ---------------------------------------------------------------------------
-- HIGH-4: the capability gate is authoritative at the authenticated adapter,
-- not merely at dispatch/write paths.  Service-role source-review functions
-- remain directly testable while product callers cannot cross R0 accidentally.
-- ---------------------------------------------------------------------------

create or replace function private.fn_capability_reader_enabled_v1(p_capability text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select g.release_stage = 'P1'
       and g.reader_enabled
       and not g.mutation_paused
    from private.canonical_capability_gates g
    where g.capability = p_capability
  ), false);
$$;
revoke all on function private.fn_capability_reader_enabled_v1(text)
  from public, anon, authenticated;
grant execute on function private.fn_capability_reader_enabled_v1(text)
  to service_role;

create or replace function public.get_my_daily_brief(p_local_date date default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.fn_capability_reader_enabled_v1('daily_brief_v2') then
    raise exception 'CAPABILITY_READER_NOT_ENABLED:daily_brief_v2';
  end if;
  return public.server_read_daily_brief(auth.uid(), p_local_date);
end;
$$;

create or replace function public.get_my_shopping_workspace()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.fn_capability_reader_enabled_v1('shopping_responsibility_v2') then
    raise exception 'CAPABILITY_READER_NOT_ENABLED:shopping_responsibility_v2';
  end if;
  return public.server_read_shopping_workspace(auth.uid());
end;
$$;

create or replace function public.get_my_request_workspace()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.fn_capability_reader_enabled_v1('request_negotiation_v2') then
    raise exception 'CAPABILITY_READER_NOT_ENABLED:request_negotiation_v2';
  end if;
  return public.server_read_request_workspace(auth.uid());
end;
$$;

create or replace function public.get_my_task_result_history(p_since_local_date date default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.fn_capability_reader_enabled_v1('actual_reconciliation_v2') then
    raise exception 'CAPABILITY_READER_NOT_ENABLED:actual_reconciliation_v2';
  end if;
  return public.server_read_task_result_history(auth.uid(), p_since_local_date);
end;
$$;

revoke all on function public.get_my_daily_brief(date) from public, anon;
revoke all on function public.get_my_shopping_workspace() from public, anon;
revoke all on function public.get_my_request_workspace() from public, anon;
revoke all on function public.get_my_task_result_history(date) from public, anon;
grant execute on function public.get_my_daily_brief(date) to authenticated;
grant execute on function public.get_my_shopping_workspace() to authenticated;
grant execute on function public.get_my_request_workspace() to authenticated;
grant execute on function public.get_my_task_result_history(date) to authenticated;

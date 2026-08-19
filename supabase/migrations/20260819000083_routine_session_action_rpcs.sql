-- WP8 (Routine LINE automation): user-facing routine-session RPCs
-- (17_ROUTINE_LINE_AUTOMATION.md #8 "LINE内input contract", #9 "PWA
-- check-in screen") backing get-routine-session / complete-routine-session /
-- routine-session-item-action.
--
-- #9 "LINEとPWAは同じmutation APIを使う。sourceだけtask_eventへ記録する" requires
-- a source tag on every completion this WP produces. WP2's
-- server_tx_complete_task (20260819000016_task_instance_mutations.sql)
-- hardcodes source='pwa' in its task_events insert. Rather than
-- reimplementing whole/subtasks completion + linked-request lifecycle here
-- (duplicating WP2's already-reviewed logic — #8 "通常complete-task
-- contractを通す" explicitly says to reuse it), this migration amends
-- server_tx_complete_task in place (same house-style precedent as WP3's
-- private.materialize_recurrence_rule amendment and this WP's own
-- server_tx_reassign_task_once amendment in 20260819000081) to add a
-- trailing `p_source text default 'pwa'` parameter. A DEFAULT-valued
-- trailing parameter added via CREATE OR REPLACE is call-compatible with
-- every existing 5-arg caller (the complete-task Edge Function,
-- process-line-inbox's complete_task postback branch) — neither needs any
-- change. The idempotency request_hash intentionally still excludes source
-- (it is delivery-channel metadata, not business intent) so hash values for
-- pre-existing receipts are unaffected.
--
-- CREATE OR REPLACE only replaces a function with an IDENTICAL parameter
-- list; adding a new trailing parameter creates a second overload instead of
-- replacing the original, which left both the old 5-arg and new 6-arg forms
-- resolvable and made any call passing an untyped literal (e.g. plain
-- `null` for p_complete_remaining_subtasks, as tests/sql/10 already did)
-- ambiguous. The old 5-arg signature is dropped first so exactly one
-- version of this function exists.
drop function if exists public.server_tx_complete_task(uuid, uuid, uuid, text, boolean);

create or replace function public.server_tx_complete_task(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_completion_actor text,
  p_complete_remaining_subtasks boolean,
  p_source text default 'pwa'
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
  v_task record;
  v_resolved_actor uuid;
  v_result jsonb;
  v_request record;
  v_source text := coalesce(p_source, 'pwa');
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_completion_actor not in ('self', 'partner') then
    raise exception 'INVALID_INPUT';
  end if;
  if v_source not in ('pwa', 'line') then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'complete-task|' || p_task_id::text || '|' || p_completion_actor || '|'
        || coalesce(p_complete_remaining_subtasks::text, ''),
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'complete-task', v_request_hash)
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

  if p_completion_actor = 'self' then
    v_resolved_actor := p_actor_id;
  else
    select user_id into v_resolved_actor
    from public.household_members
    where household_id = v_household_id and user_id <> p_actor_id
    limit 1;
    if v_resolved_actor is null then
      raise exception 'INVALID_INPUT';
    end if;
  end if;

  select * into v_task
  from public.task_instances
  where household_id = v_household_id and id = p_task_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_task.status not in ('todo', 'in_progress') then
    raise exception 'TASK_TERMINAL';
  end if;

  if v_task.completion_mode = 'whole' then
    update public.task_instances
    set status = 'completed', completed_at = now(), actual_completed_by_id = v_resolved_actor
    where household_id = v_household_id and id = p_task_id;
  else
    if coalesce(p_complete_remaining_subtasks, false) is not true then
      raise exception 'INVALID_INPUT';
    end if;

    perform 1 from public.task_subtask_instances
    where household_id = v_household_id and task_instance_id = p_task_id
    for update;

    update public.task_subtask_instances
    set is_completed = true, completed_by = v_resolved_actor, completed_at = now()
    where household_id = v_household_id and task_instance_id = p_task_id
      and required and not is_completed;

    update public.task_instances
    set status = 'completed', completed_at = now()
    where household_id = v_household_id and id = p_task_id;
  end if;

  select * into v_request
  from public.requests
  where household_id = v_household_id and linked_task_instance_id = p_task_id and status = 'accepted'
  for update;

  if found then
    update public.requests
    set status = 'completed', completed_at = now()
    where household_id = v_household_id and id = v_request.id;
  end if;

  insert into public.task_events
    (household_id, task_instance_id, actor_id, event_type, source, idempotency_key)
  values
    (v_household_id, p_task_id, p_actor_id, 'completed', v_source, p_operation_id::text || ':completed');

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'task_instance', result_id = p_task_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_complete_task(uuid, uuid, uuid, text, boolean, text) from public;
revoke all on function public.server_tx_complete_task(uuid, uuid, uuid, text, boolean, text) from anon;
revoke all on function public.server_tx_complete_task(uuid, uuid, uuid, text, boolean, text) from authenticated;
grant execute on function public.server_tx_complete_task(uuid, uuid, uuid, text, boolean, text) to service_role;

-- ---------------------------------------------------------------------------
-- get-routine-session (read; verify_jwt=true Edge Function, any household
-- member — #9 "LINEとPWAは同じmutation APIを使う" / SL-16 "same canonical
-- task/session state visible" implies cross-viewing is fine, only mutation
-- is recipient-restricted, enforced by the two functions below via
-- assignee_id = p_actor_id).
-- ---------------------------------------------------------------------------
create or replace function public.server_tx_get_routine_session(
  p_actor_id uuid,
  p_session_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_session record;
  v_items jsonb;
  v_current_session_id uuid;
  v_result jsonb;
begin
  if p_actor_id is null or p_session_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  select * into v_session
  from public.routine_checkin_sessions
  where household_id = v_household_id and id = p_session_id;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_instance_id', ti.id,
    'title', ti.title,
    'status', ti.status,
    'completion_mode', ti.completion_mode,
    'actual_completed_by_id', ti.actual_completed_by_id,
    'display_order', rcsi.display_order,
    'subtasks', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', st.id, 'title', st.title, 'required', st.required,
        'is_completed', st.is_completed, 'completed_by', st.completed_by
      ) order by st.sort_order), '[]'::jsonb)
      from public.task_subtask_instances st
      where st.household_id = v_household_id and st.task_instance_id = ti.id
    )
  ) order by rcsi.display_order), '[]'::jsonb) into v_items
  from public.routine_checkin_session_items rcsi
  join public.task_instances ti on ti.household_id = v_household_id and ti.id = rcsi.task_instance_id
  where rcsi.household_id = v_household_id and rcsi.session_id = p_session_id;

  v_current_session_id := null;
  if v_session.status = 'superseded' then
    -- SL-30 "old superseded session PWA link opened -> readable context,
    -- mutation disabled, link to current Today/session".
    select id into v_current_session_id
    from public.routine_checkin_sessions
    where household_id = v_household_id and session_type = v_session.session_type
      and scheduled_date = v_session.scheduled_date and status <> 'superseded'
    order by opened_at desc
    limit 1;
  end if;

  v_result := jsonb_build_object(
    'id', v_session.id,
    'session_type', v_session.session_type,
    'scheduled_date', v_session.scheduled_date,
    'assignee_id', v_session.assignee_id,
    'status', v_session.status,
    'assignment_generation', v_session.assignment_generation,
    'opened_at', v_session.opened_at,
    'submitted_at', v_session.submitted_at,
    'can_act', (v_session.status = 'open' and v_session.assignee_id = p_actor_id),
    'current_session_id', v_current_session_id,
    'items', v_items
  );

  return v_result;
end;
$$;

revoke all on function public.server_tx_get_routine_session(uuid, uuid) from public;
revoke all on function public.server_tx_get_routine_session(uuid, uuid) from anon;
revoke all on function public.server_tx_get_routine_session(uuid, uuid) from authenticated;
grant execute on function public.server_tx_get_routine_session(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- routine-session-item-action: #8 "項目ごとに入力" per-item actions
-- (完了/相手が対応/今回は不要). p_source distinguishes a LINE-postback-shaped
-- call from a PWA-shaped one (#9). Mutation restricted to the session's own
-- assignee (#8 "RLS/Edge authorizationでrecipient本人のみ操作可能").
-- ---------------------------------------------------------------------------
create or replace function public.server_tx_routine_session_item_action(
  p_actor_id uuid,
  p_operation_id uuid,
  p_session_id uuid,
  p_task_instance_id uuid,
  p_action text,
  p_source text
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
  v_session record;
  v_task record;
  v_sub_op uuid;
  v_remaining int;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_session_id is null
     or p_task_instance_id is null or p_action is null or p_source is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_action not in ('complete', 'partner_handled', 'skip') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_source not in ('pwa', 'line') then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'routine-session-item-action|' || p_session_id::text || '|' || p_task_instance_id::text
        || '|' || p_action || '|' || p_source,
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'routine-session-item-action', v_request_hash)
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

  select * into v_session
  from public.routine_checkin_sessions
  where household_id = v_household_id and id = p_session_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_session.assignee_id <> p_actor_id then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  -- SL-17 "user completes via PWA then taps stale LINE item -> idempotent
  -- current state or safe terminal response; no rewind": a superseded/
  -- already-submitted/auto_closed session never accepts a new item action.
  if v_session.status <> 'open' then
    raise exception 'TASK_TERMINAL';
  end if;

  if not exists (
    select 1 from public.routine_checkin_session_items
    where household_id = v_household_id and session_id = p_session_id and task_instance_id = p_task_instance_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  select * into v_task
  from public.task_instances
  where household_id = v_household_id and id = p_task_instance_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  -- SL-17's other half: the item is already terminal (e.g. completed via
  -- PWA moments earlier) — report the current state back rather than error,
  -- so a stale LINE tap never rewinds anything.
  if v_task.status not in ('todo', 'in_progress') then
    v_result := jsonb_build_object('ok', true, 'task_id', p_task_instance_id, 'status', v_task.status, 'already_terminal', true);
    update private.mutation_receipts
    set result_type = 'task_instance', result_id = p_task_instance_id, result_payload = v_result
    where actor_id = p_actor_id and operation_id = p_operation_id;
    return v_result;
  end if;

  v_sub_op := (md5(p_operation_id::text || ':' || p_task_instance_id::text))::uuid;

  if p_action = 'complete' then
    perform public.server_tx_complete_task(p_actor_id, v_sub_op, p_task_instance_id, 'self', true, p_source);
  elsif p_action = 'partner_handled' then
    perform public.server_tx_complete_task(p_actor_id, v_sub_op, p_task_instance_id, 'partner', true, p_source);
  else -- skip
    update public.task_instances
    set status = 'skipped'
    where household_id = v_household_id and id = p_task_instance_id;

    insert into public.task_events
      (household_id, task_instance_id, actor_id, event_type, source, idempotency_key)
    values
      (v_household_id, p_task_instance_id, p_actor_id, 'skipped', p_source, p_operation_id::text || ':skipped');
  end if;

  -- Finalize the session once every item in it is terminal (#8 "session
  -- finalizationは全item判定後").
  select count(*) into v_remaining
  from public.routine_checkin_session_items rcsi
  join public.task_instances ti on ti.household_id = v_household_id and ti.id = rcsi.task_instance_id
  where rcsi.household_id = v_household_id and rcsi.session_id = p_session_id
    and ti.status in ('todo', 'in_progress');

  if v_remaining = 0 then
    update public.routine_checkin_sessions
    set status = 'submitted', submitted_at = now()
    where id = p_session_id and status = 'open';
  end if;

  v_result := jsonb_build_object('ok', true, 'task_id', p_task_instance_id, 'action', p_action, 'session_remaining', v_remaining);

  update private.mutation_receipts
  set result_type = 'task_instance', result_id = p_task_instance_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_routine_session_item_action(uuid, uuid, uuid, uuid, text, text) from public;
revoke all on function public.server_tx_routine_session_item_action(uuid, uuid, uuid, uuid, text, text) from anon;
revoke all on function public.server_tx_routine_session_item_action(uuid, uuid, uuid, uuid, text, text) from authenticated;
grant execute on function public.server_tx_routine_session_item_action(uuid, uuid, uuid, uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- complete-routine-session: #8 top-level "全部完了" / confirmed "今回は不要".
-- ---------------------------------------------------------------------------
create or replace function public.server_tx_complete_routine_session(
  p_actor_id uuid,
  p_operation_id uuid,
  p_session_id uuid,
  p_disposition text,
  p_source text
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
  v_session record;
  v_item record;
  v_sub_op uuid;
  v_completed_count int := 0;
  v_skipped_count int := 0;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_session_id is null
     or p_disposition is null or p_source is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_disposition not in ('complete_all', 'skip_incomplete') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_source not in ('pwa', 'line') then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'complete-routine-session|' || p_session_id::text || '|' || p_disposition || '|' || p_source,
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'complete-routine-session', v_request_hash)
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

  select * into v_session
  from public.routine_checkin_sessions
  where household_id = v_household_id and id = p_session_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_session.assignee_id <> p_actor_id then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_session.status <> 'open' then
    raise exception 'TASK_TERMINAL';
  end if;

  for v_item in
    select ti.id
    from public.routine_checkin_session_items rcsi
    join public.task_instances ti on ti.household_id = v_household_id and ti.id = rcsi.task_instance_id
    where rcsi.household_id = v_household_id and rcsi.session_id = p_session_id
      and ti.status in ('todo', 'in_progress')
    order by rcsi.display_order
  loop
    v_sub_op := (md5(p_operation_id::text || ':' || v_item.id::text))::uuid;
    if p_disposition = 'complete_all' then
      perform public.server_tx_complete_task(p_actor_id, v_sub_op, v_item.id, 'self', true, p_source);
      v_completed_count := v_completed_count + 1;
    else
      update public.task_instances set status = 'skipped' where household_id = v_household_id and id = v_item.id;
      insert into public.task_events
        (household_id, task_instance_id, actor_id, event_type, source, idempotency_key)
      values
        (v_household_id, v_item.id, p_actor_id, 'skipped', p_source, v_sub_op::text || ':skipped')
      on conflict do nothing;
      v_skipped_count := v_skipped_count + 1;
    end if;
  end loop;

  update public.routine_checkin_sessions
  set status = 'submitted', submitted_at = now()
  where id = p_session_id;

  v_result := jsonb_build_object(
    'ok', true, 'session_id', p_session_id, 'disposition', p_disposition,
    'completed_count', v_completed_count, 'skipped_count', v_skipped_count
  );

  update private.mutation_receipts
  set result_type = 'routine_checkin_session', result_id = p_session_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_complete_routine_session(uuid, uuid, uuid, text, text) from public;
revoke all on function public.server_tx_complete_routine_session(uuid, uuid, uuid, text, text) from anon;
revoke all on function public.server_tx_complete_routine_session(uuid, uuid, uuid, text, text) from authenticated;
grant execute on function public.server_tx_complete_routine_session(uuid, uuid, uuid, text, text) to service_role;

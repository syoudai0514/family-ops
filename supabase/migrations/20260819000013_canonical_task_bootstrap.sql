-- v6 re-review fix (P1 #3): a fresh household must never start with zero
-- canonical task definitions — otherwise configure-evening-routines has
-- nothing to configure and the "no silent empty-night state" guarantee is
-- hollow. Bootstraps the exact 13 task_definitions (+ subtasks) from
-- docs/design/v6/fixtures/INITIAL_TASK_SEED.yaml, idempotently, and wires
-- it into server_tx_create_household so every household gets them from the
-- moment it exists — never inserted by hand in a test or by an Edge
-- Function. Weekday-specific dropoff/pickup *recurrence rules* (which need
-- an actual assignee decision from the couple) are intentionally NOT
-- bootstrapped here — only the definitions/subtasks, matching the fixture's
-- own note that "actual dropoff/pickup clock times must be collected during
-- setup" and 03_DOMAIN_AND_DATA_MODEL.md's "never guess a user" rule.

create or replace function private.bootstrap_canonical_task_definitions(
  p_household_id uuid,
  p_actor_id uuid
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_def jsonb;
  v_sub jsonb;
  v_task_id uuid;
  -- docs/design/v6/fixtures/INITIAL_TASK_SEED.yaml task_definitions, verbatim.
  v_definitions jsonb := '[
    {"code":"dropoff","title":"送り","category":"dropoff","routine_phase":"morning","completion_mode":"whole","sort_order":10},
    {"code":"pickup","title":"お迎え","category":"pickup","routine_phase":"evening","completion_mode":"whole","sort_order":20},
    {"code":"prep_monday_bedding","title":"昼寝用寝具を入れる","category":"preparation","routine_phase":"morning","completion_mode":"whole","sort_order":30},
    {"code":"prep_monday_uwabaki","title":"洗った上履きを持っていく","category":"preparation","routine_phase":"morning","completion_mode":"whole","sort_order":31},
    {"code":"prep_tuesday_gym","title":"年長の体操教室用品を準備する","category":"preparation","routine_phase":"morning","completion_mode":"whole","sort_order":32},
    {"code":"prep_thursday_english","title":"英語用品を準備する","category":"preparation","routine_phase":"morning","completion_mode":"whole","sort_order":33},
    {"code":"dinner","title":"夕食対応","category":"meal","routine_phase":"evening","completion_mode":"subtasks","sort_order":100,
      "subtasks":[{"title":"食事を準備","required":true,"sort_order":1},{"title":"配膳","required":true,"sort_order":2},{"title":"子どもに食べさせる","required":true,"sort_order":3},{"title":"食卓片付け","required":true,"sort_order":4}]},
    {"code":"bath","title":"お風呂","category":"bath","routine_phase":"evening","completion_mode":"whole","sort_order":110},
    {"code":"laundry","title":"洗濯","category":"laundry","routine_phase":"evening","completion_mode":"subtasks","sort_order":120,
      "subtasks":[{"title":"回す","required":true,"sort_order":1},{"title":"干す/乾燥","required":true,"sort_order":2},{"title":"取り込む","required":true,"sort_order":3},{"title":"畳む","required":true,"sort_order":4},{"title":"収納","required":true,"sort_order":5}]},
    {"code":"dishes","title":"食器洗い","category":"dishes","routine_phase":"evening","completion_mode":"whole","sort_order":130},
    {"code":"cleaning","title":"掃除","category":"cleaning","routine_phase":"evening","completion_mode":"subtasks","sort_order":140,
      "subtasks":[{"title":"リビング床","required":true,"sort_order":1},{"title":"食べこぼし","required":true,"sort_order":2},{"title":"テーブル","required":true,"sort_order":3}]},
    {"code":"smile_zemi","title":"スマイルゼミ","category":"learning","routine_phase":"evening","completion_mode":"whole","sort_order":150},
    {"code":"media_30min","title":"スマイルゼミ後のテレビ/ゲーム30分管理","category":"child_routine","routine_phase":"evening","completion_mode":"whole","sort_order":160}
  ]'::jsonb;
begin
  for v_def in select * from jsonb_array_elements(v_definitions)
  loop
    insert into public.task_definitions
      (household_id, code, title, category, routine_phase, completion_mode, sort_order, created_by)
    values (
      p_household_id, v_def->>'code', v_def->>'title', v_def->>'category',
      v_def->>'routine_phase', v_def->>'completion_mode', (v_def->>'sort_order')::int, p_actor_id
    )
    on conflict (household_id, code) do nothing;

    select id into v_task_id
    from public.task_definitions
    where household_id = p_household_id and code = v_def->>'code';

    if v_def ? 'subtasks' then
      for v_sub in select * from jsonb_array_elements(v_def->'subtasks')
      loop
        insert into public.task_subtask_definitions
          (household_id, task_definition_id, title, required, sort_order)
        select p_household_id, v_task_id, v_sub->>'title', (v_sub->>'required')::boolean, (v_sub->>'sort_order')::int
        where not exists (
          select 1 from public.task_subtask_definitions
          where household_id = p_household_id and task_definition_id = v_task_id and title = v_sub->>'title'
        );
      end loop;
    end if;
  end loop;
end;
$$;

revoke all on function private.bootstrap_canonical_task_definitions(uuid, uuid) from public;
revoke all on function private.bootstrap_canonical_task_definitions(uuid, uuid) from anon;
revoke all on function private.bootstrap_canonical_task_definitions(uuid, uuid) from authenticated;
grant execute on function private.bootstrap_canonical_task_definitions(uuid, uuid) to service_role;

-- Re-wire server_tx_create_household to call the bootstrap immediately after
-- the household/membership/routine-schedule rows in the same transaction.
create or replace function public.server_tx_create_household(
  p_actor_id uuid,
  p_operation_id uuid,
  p_household_name text,
  p_display_name text
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
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if coalesce(btrim(p_household_name), '') = '' or coalesce(btrim(p_display_name), '') = '' then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to('create-household|' || p_household_name || '|' || p_display_name, 'UTF8')),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'create-household', v_request_hash)
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

  perform pg_advisory_xact_lock(hashtext('fo_membership_actor:' || p_actor_id::text));

  perform 1 from public.household_members where user_id = p_actor_id;
  if found then
    raise exception 'HOUSEHOLD_ALREADY_JOINED';
  end if;

  insert into public.households (name, timezone)
  values (p_household_name, 'Asia/Tokyo')
  returning id into v_household_id;

  insert into public.profiles (user_id, display_name)
  values (p_actor_id, p_display_name)
  on conflict (user_id) do update set display_name = excluded.display_name;

  insert into public.household_members (household_id, user_id, member_role, joined_at)
  values (v_household_id, p_actor_id, 'adult', now());

  insert into public.household_routine_schedules
    (household_id, schedule_kind, weekday, local_time, updated_by)
  values
    (v_household_id, 'daily_assignment', null, time '07:00', p_actor_id),
    (v_household_id, 'dropoff_checklist', null, time '07:00', p_actor_id),
    (v_household_id, 'dropoff_checkin', null, time '08:30', p_actor_id),
    (v_household_id, 'pickup_checklist', null, time '16:00', p_actor_id),
    (v_household_id, 'pickup_checkin', null, time '20:30', p_actor_id),
    (v_household_id, 'nonpickup_evening_checklist', null, time '20:00', p_actor_id),
    (v_household_id, 'nonpickup_evening_checkin', null, time '22:00', p_actor_id),
    (v_household_id, 'nonworkday_morning_digest', null, time '09:00', p_actor_id),
    (v_household_id, 'nonworkday_checkin', null, time '20:00', p_actor_id);

  insert into public.notification_preferences (household_id, user_id)
  values (v_household_id, p_actor_id);

  perform private.bootstrap_canonical_task_definitions(v_household_id, p_actor_id);

  v_result := jsonb_build_object('household_id', v_household_id);

  update private.mutation_receipts
  set result_type = 'household', result_id = v_household_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_create_household(uuid, uuid, text, text) from public;
revoke all on function public.server_tx_create_household(uuid, uuid, text, text) from anon;
revoke all on function public.server_tx_create_household(uuid, uuid, text, text) from authenticated;
grant execute on function public.server_tx_create_household(uuid, uuid, text, text) to service_role;

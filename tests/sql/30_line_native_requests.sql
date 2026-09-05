-- LINE-native preview editing and general-request handoff.
-- These contracts keep natural-language input sender-private until explicit
-- confirmation, and ensure the recipient's LINE buttons are durable pending
-- actions rather than an immediate task reassignment.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('f1000000-0000-0000-0000-000000000001'),
  ('f1000000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_household jsonb;
  v_household_id uuid;
  v_pending jsonb;
  v_pending_id uuid;
  v_result jsonb;
  v_request_id uuid;
  v_action_count int;
begin
  v_household := public.server_tx_create_household(
    'f1000000-0000-0000-0000-000000000001', gen_random_uuid(), 'LINE Native HH', 'Owner'
  );
  v_household_id := (v_household->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_household_id, 'f1000000-0000-0000-0000-000000000002', 'adult');

  -- Sender preview is editable only while it is this sender's draft.
  v_pending := public.server_tx_create_pending_action(
    'f1000000-0000-0000-0000-000000000001', v_household_id, gen_random_uuid(), 'line',
    'task_create_once',
    jsonb_build_object('title', '病院の保険証を準備', 'scheduled_date', '2026-08-22',
      'due_local_time', '20:00', 'planned_assignee_user_id', 'f1000000-0000-0000-0000-000000000002'),
    30
  );
  v_pending_id := (v_pending->>'pending_action_id')::uuid;
  insert into private.line_user_links (household_id, user_id, line_user_id)
  values (v_household_id, 'f1000000-0000-0000-0000-000000000001', 'line-conversation-owner');
  v_result := public.server_tx_get_line_conversation_pending(
    'f1000000-0000-0000-0000-000000000001', 'line-conversation-owner'
  );
  if (v_result->>'id')::uuid <> v_pending_id or v_result->>'status' <> 'draft'
     or (v_result->>'revision')::bigint <> 0 then
    raise exception 'FAIL line-native: LINE follow-up must resolve owner draft with visible draft state/revision';
  end if;
  if public.server_tx_get_line_conversation_pending(
    'f1000000-0000-0000-0000-000000000002', 'line-conversation-owner'
  ) is not null then
    raise exception 'FAIL line-native: LINE conversation context leaked to another actor';
  end if;
  v_result := public.server_tx_get_pending_action('f1000000-0000-0000-0000-000000000001', v_pending_id);
  if v_result->>'action_type' <> 'task_create_once' then
    raise exception 'FAIL line-native: sender must read own task preview';
  end if;

  v_result := public.server_tx_update_pending_action(
    'f1000000-0000-0000-0000-000000000001', v_pending_id, 'task_create_once',
    jsonb_build_object('title', '病院の保険証を準備', 'scheduled_date', '2026-08-22',
      'due_local_time', '20:00', 'planned_assignee_user_id', 'f1000000-0000-0000-0000-000000000002'),
    (v_result->>'revision')::bigint
  );
  if v_result->'normalized_payload'->>'planned_assignee_user_id' <> 'f1000000-0000-0000-0000-000000000002'
     or (v_result->>'revision')::bigint <> 1 then
    raise exception 'FAIL line-native: task preview edit must preserve assignee and advance revision';
  end if;

  -- A typed LINE correction may only discover the sender's explicitly opened
  -- draft.  The worker will apply the structured "パパに変更" patch through
  -- server_tx_update_pending_action; this getter must never expose it to the
  -- partner or select an unrelated draft.
  v_result := public.server_tx_update_pending_action(
    'f1000000-0000-0000-0000-000000000001', v_pending_id, 'task_create_once',
    jsonb_build_object('title', '病院の保険証を準備', 'scheduled_date', '2026-08-22',
      'due_local_time', '20:00', 'planned_assignee_user_id', 'f1000000-0000-0000-0000-000000000002',
      'line_edit_mode', true),
    (v_result->>'revision')::bigint
  );
  v_result := public.server_tx_get_line_pending_text_edit('f1000000-0000-0000-0000-000000000001');
  if (v_result->>'id')::uuid <> v_pending_id or v_result->'normalized_payload'->>'line_edit_mode' <> 'true'
     or (v_result->>'revision')::bigint <> 2 then
    raise exception 'FAIL line-native: sender must recover only active text-edit draft at current revision';
  end if;
  if public.server_tx_get_line_pending_text_edit('f1000000-0000-0000-0000-000000000002') is not null then
    raise exception 'FAIL line-native: partner must not discover sender text-edit draft';
  end if;

  begin
    perform public.server_tx_get_pending_action('f1000000-0000-0000-0000-000000000002', v_pending_id);
    raise exception 'FAIL line-native: another user must not read sender preview';
  exception when others then
    if sqlerrm <> 'PENDING_ACTION_NOT_EDITABLE' then raise; end if;
  end;

  perform public.server_tx_confirm_pending_action('f1000000-0000-0000-0000-000000000001', v_pending_id);
  v_result := public.server_tx_get_line_conversation_pending(
    'f1000000-0000-0000-0000-000000000001', 'line-conversation-owner'
  );
  if (v_result->>'id')::uuid <> v_pending_id or v_result->>'status' <> 'confirmed' then
    raise exception 'FAIL line-native: confirmed follow-up must remain visible as terminal/current state, never a new draft';
  end if;
  begin
    perform public.server_tx_update_pending_action(
      'f1000000-0000-0000-0000-000000000001', v_pending_id, 'task_create_once', '{}'::jsonb,
      (v_result->>'revision')::bigint
    );
    raise exception 'FAIL line-native: confirmed preview must not be editable';
  exception when others then
    if sqlerrm <> 'PENDING_ACTION_NOT_EDITABLE' then raise; end if;
  end;

  -- The request stays pending until the recipient confirms its own LINE action.
  v_result := public.server_tx_send_request(
    'f1000000-0000-0000-0000-000000000001', gen_random_uuid(),
    'f1000000-0000-0000-0000-000000000002', '歯医者の予約',
    '歯医者の予約をお願いできますか？', '2026-08-23 08:00:00+09'
  );
  v_request_id := (v_result->>'request_id')::uuid;
  if (select status from public.requests where id = v_request_id) <> 'pending' then
    raise exception 'FAIL line-native: request must remain pending before recipient accept';
  end if;
  select count(*) into v_action_count
  from private.pending_actions
  where household_id = v_household_id
    and actor_id = 'f1000000-0000-0000-0000-000000000002'
    and action_type in ('request_accept', 'request_decline')
    and normalized_payload->>'request_id' = v_request_id::text;
  if v_action_count <> 2 then
    raise exception 'FAIL line-native: recipient must receive exactly accept and decline pending actions, got %', v_action_count;
  end if;
  if exists (
    select 1 from public.user_notifications
    where household_id = v_household_id and recipient_user_id = 'f1000000-0000-0000-0000-000000000002'
      and body like '%raw_text%'
  ) then
    raise exception 'FAIL line-native: raw LINE text must never be sent to recipient';
  end if;
end;
$$;

reset role;
select 'line_native_requests: PASS' as result;

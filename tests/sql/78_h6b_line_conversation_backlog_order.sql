-- H6-B real LINE regression: expiring old drafts must not reorder conversation
-- recency and shadow the sender's fresh draft.
\set ON_ERROR_STOP on

insert into auth.users (id) values ('a5000000-0000-0000-0000-000000000001');

set role service_role;
do $$
declare
  v_actor uuid := 'a5000000-0000-0000-0000-000000000001';
  v_household jsonb;
  v_household_id uuid;
  v_old jsonb;
  v_old_id uuid;
  v_fresh jsonb;
  v_fresh_id uuid;
  v_read jsonb;
  v_old_updated_at timestamptz;
  v_fresh_updated_at timestamptz;
begin
  v_household := public.server_tx_create_household(
    v_actor, gen_random_uuid(), 'H6-B backlog HH', 'Owner'
  );
  v_household_id := (v_household->>'household_id')::uuid;

  insert into private.line_user_links (
    household_id, user_id, line_user_id, status
  ) values (
    v_household_id, v_actor, 'U-H6B-BACKLOG-ORDER', 'active'
  );

  v_old := public.server_tx_create_pending_action(
    v_actor, v_household_id, gen_random_uuid(),
    'line', 'needs_pwa_review',
    jsonb_build_object('raw_text','古い会話'), 30
  );
  v_old_id := (v_old->>'pending_action_id')::uuid;

  -- Reproduce the production backlog: the historical draft is already past
  -- its TTL, while its original conversation creation time is much older.
  update private.pending_actions
  set expires_at = now() - interval '1 minute',
      created_at = now() - interval '1 day',
      updated_at = now() - interval '1 day'
  where id = v_old_id;

  v_fresh := public.server_tx_create_pending_action(
    v_actor, v_household_id, gen_random_uuid(),
    'line', 'task_create_once',
    jsonb_build_object(
      'title','ゴミ出し',
      'raw_text','明日の夜にゴミ出しをする',
      'scheduled_date','2026-09-07',
      'due_local_time','20:00'
    ), 30
  );
  v_fresh_id := (v_fresh->>'pending_action_id')::uuid;

  v_read := public.server_tx_get_line_conversation_pending(
    v_actor, 'U-H6B-BACKLOG-ORDER'
  );

  select updated_at into v_old_updated_at
  from private.pending_actions where id = v_old_id;
  select updated_at into v_fresh_updated_at
  from private.pending_actions where id = v_fresh_id;

  if (select status from private.pending_actions where id = v_old_id) <> 'expired' then
    raise exception 'FAIL h6b-backlog: old elapsed draft was not expired';
  end if;

  -- The lazy expiry deliberately updates the old row after the fresh draft.
  -- This assertion makes sure the regression fixture really reproduces the
  -- production ordering hazard that existed with ORDER BY updated_at.
  if v_old_updated_at <= v_fresh_updated_at then
    raise exception 'FAIL h6b-backlog: fixture did not advance old updated_at';
  end if;

  if (v_read->>'id')::uuid <> v_fresh_id
     or v_read->>'status' <> 'draft'
     or v_read->'normalized_payload'->>'title' <> 'ゴミ出し' then
    raise exception 'FAIL h6b-backlog: expired historical row shadowed fresh LINE draft';
  end if;

  perform public.server_tx_cancel_pending_action(v_actor, v_fresh_id);
  v_read := public.server_tx_get_line_conversation_pending(
    v_actor, 'U-H6B-BACKLOG-ORDER'
  );

  if (v_read->>'id')::uuid <> v_fresh_id
     or v_read->>'status' <> 'cancelled' then
    raise exception 'FAIL h6b-backlog: terminal cancel changed conversation referent';
  end if;
end;
$$;

reset role;
select 'h6b_line_conversation_backlog_order: PASS' as result;

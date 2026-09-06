-- Q4/Q70/Q71: stale/out-of-order LINE corrections must not overwrite a
-- newer draft value.  Revision protects concurrent writers and the LINE
-- provider timestamp protects an older follow-up that is delivered late.
\set ON_ERROR_STOP on

insert into auth.users (id) values ('a4000000-0000-0000-0000-000000000001');

set role service_role;
do $$
declare
  v_household jsonb;
  v_household_id uuid;
  v_pending jsonb;
  v_pending_id uuid;
  v_read jsonb;
  v_first jsonb;
  v_after jsonb;
  v_second jsonb;
  v_title text;
begin
  v_household := public.server_tx_create_household(
    'a4000000-0000-0000-0000-000000000001', gen_random_uuid(), 'LINE CAS HH', 'Owner'
  );
  v_household_id := (v_household->>'household_id')::uuid;

  v_pending := public.server_tx_create_pending_action(
    'a4000000-0000-0000-0000-000000000001', v_household_id, gen_random_uuid(),
    'line', 'task_create_once', jsonb_build_object('title','最初','scheduled_date','2026-09-06'), 30
  );
  v_pending_id := (v_pending->>'pending_action_id')::uuid;
  v_read := public.server_tx_get_pending_action(
    'a4000000-0000-0000-0000-000000000001', v_pending_id
  );
  if (v_read->>'revision')::bigint <> 0 then
    raise exception 'FAIL line-cas: new draft revision must start at zero';
  end if;

  -- Simulate two corrections that both observed revision 0.  The first wins.
  v_first := public.server_tx_update_pending_action(
    'a4000000-0000-0000-0000-000000000001', v_pending_id, 'task_create_once',
    jsonb_build_object('title','新しい値','scheduled_date','2026-09-07'),
    (v_read->>'revision')::bigint, 2000
  );
  if (v_first->>'revision')::bigint <> 1
     or (v_first->>'last_line_event_timestamp')::bigint <> 2000 then
    raise exception 'FAIL line-cas: successful correction did not advance revision/event watermark';
  end if;

  begin
    perform public.server_tx_update_pending_action(
      'a4000000-0000-0000-0000-000000000001', v_pending_id, 'task_create_once',
      jsonb_build_object('title','競合した別の値','scheduled_date','2026-09-07'),
      (v_read->>'revision')::bigint, 3000
    );
    raise exception 'FAIL line-cas: stale concurrent correction unexpectedly succeeded';
  exception when others then
    if sqlerrm <> 'PENDING_ACTION_STALE' then raise; end if;
  end;

  -- Even after re-reading the current revision, a provider event older than
  -- the accepted event may not roll the draft back.
  v_after := public.server_tx_get_pending_action(
    'a4000000-0000-0000-0000-000000000001', v_pending_id
  );
  begin
    perform public.server_tx_update_pending_action(
      'a4000000-0000-0000-0000-000000000001', v_pending_id, 'task_create_once',
      jsonb_build_object('title','古い値へ巻き戻し','scheduled_date','2026-09-06'),
      (v_after->>'revision')::bigint, 1500
    );
    raise exception 'FAIL line-cas: out-of-order older LINE event unexpectedly succeeded';
  exception when others then
    if sqlerrm <> 'PENDING_ACTION_STALE' then raise; end if;
  end;

  select normalized_payload->>'title' into v_title
  from private.pending_actions where id=v_pending_id;
  if v_title <> '新しい値' then
    raise exception 'FAIL line-cas: stale/out-of-order correction rolled back newer value';
  end if;

  -- A later event based on the current revision remains valid.
  v_second := public.server_tx_update_pending_action(
    'a4000000-0000-0000-0000-000000000001', v_pending_id, 'task_create_once',
    jsonb_build_object('title','さらに新しい値','scheduled_date','2026-09-08'),
    (v_after->>'revision')::bigint, 3000
  );
  if (v_second->>'revision')::bigint <> 2
     or v_second->'normalized_payload'->>'title' <> 'さらに新しい値'
     or (v_second->>'last_line_event_timestamp')::bigint <> 3000 then
    raise exception 'FAIL line-cas: current later correction did not succeed';
  end if;

  perform public.server_tx_confirm_pending_action(
    'a4000000-0000-0000-0000-000000000001', v_pending_id
  );
  begin
    perform public.server_tx_update_pending_action(
      'a4000000-0000-0000-0000-000000000001', v_pending_id, 'task_create_once',
      jsonb_build_object('title','確定後の復活'), (v_second->>'revision')::bigint, 4000
    );
    raise exception 'FAIL line-cas: confirmed draft was revived';
  exception when others then
    if sqlerrm <> 'PENDING_ACTION_NOT_EDITABLE' then raise; end if;
  end;
end;
$$;

reset role;
select 'line_pending_action_revision_cas: PASS' as result;

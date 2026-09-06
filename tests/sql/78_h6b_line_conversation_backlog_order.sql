-- H6-B real LINE regression: expiring old drafts must not reorder conversation
-- recency and shadow the sender's fresh draft.
--
-- The real-provider failure needs two transactions to reproduce: transaction A
-- creates the fresh conversation; transaction B (the sender's next LINE turn)
-- lazily expires historical backlog rows, whose updated_at trigger then gives
-- them a timestamp newer than the fresh draft.  Keep those boundaries here so
-- the regression matches production rather than relying on same-transaction
-- timestamp behavior.
\set ON_ERROR_STOP on

insert into auth.users (id) values ('a5000000-0000-0000-0000-000000000001');

set role service_role;

-- Transaction A: establish one historical expired-by-TTL conversation and one
-- genuinely fresh draft. set_config(..., false) preserves generated ids for the
-- following top-level statements in this psql session.
do $$
declare
  v_actor uuid := 'a5000000-0000-0000-0000-000000000001';
  v_household jsonb;
  v_household_id uuid;
  v_old jsonb;
  v_old_id uuid;
  v_fresh jsonb;
  v_fresh_id uuid;
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

  update private.pending_actions
  set expires_at = now() - interval '1 minute',
      created_at = now() - interval '1 day'
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

  perform set_config('h6b.old_id', v_old_id::text, false);
  perform set_config('h6b.fresh_id', v_fresh_id::text, false);
end;
$$;

-- Transaction B: this models the next incoming LINE turn. The lookup lazily
-- expires the old draft in this later transaction. With the pre-fix function,
-- ORDER BY updated_at would select that just-maintained historical row.
select set_config(
  'h6b.first_read',
  public.server_tx_get_line_conversation_pending(
    'a5000000-0000-0000-0000-000000000001'::uuid,
    'U-H6B-BACKLOG-ORDER'
  )::text,
  false
);

-- Verify the production ordering hazard actually exists in the fixture and the
-- fixed reader still returns the fresh conversation by immutable creation order.
do $$
declare
  v_old_id uuid := current_setting('h6b.old_id')::uuid;
  v_fresh_id uuid := current_setting('h6b.fresh_id')::uuid;
  v_read jsonb := current_setting('h6b.first_read')::jsonb;
  v_old_created_at timestamptz;
  v_fresh_created_at timestamptz;
  v_old_updated_at timestamptz;
  v_fresh_updated_at timestamptz;
begin
  select created_at, updated_at into v_old_created_at, v_old_updated_at
  from private.pending_actions where id = v_old_id;
  select created_at, updated_at into v_fresh_created_at, v_fresh_updated_at
  from private.pending_actions where id = v_fresh_id;

  if (select status from private.pending_actions where id = v_old_id) <> 'expired' then
    raise exception 'FAIL h6b-backlog: old elapsed draft was not expired';
  end if;

  if v_old_created_at >= v_fresh_created_at then
    raise exception 'FAIL h6b-backlog: fixture old conversation is not older';
  end if;
  if v_old_updated_at <= v_fresh_updated_at then
    raise exception 'FAIL h6b-backlog: later cleanup did not create updated_at shadow hazard';
  end if;

  if (v_read->>'id')::uuid <> v_fresh_id
     or v_read->>'status' <> 'draft'
     or v_read->'normalized_payload'->>'title' <> 'ゴミ出し' then
    raise exception 'FAIL h6b-backlog: expired historical row shadowed fresh LINE draft';
  end if;
end;
$$;

-- Transaction C/D: terminal state updates must not change which conversation
-- "なにを？"-style context refers to either.
select public.server_tx_cancel_pending_action(
  'a5000000-0000-0000-0000-000000000001'::uuid,
  current_setting('h6b.fresh_id')::uuid
);

select set_config(
  'h6b.second_read',
  public.server_tx_get_line_conversation_pending(
    'a5000000-0000-0000-0000-000000000001'::uuid,
    'U-H6B-BACKLOG-ORDER'
  )::text,
  false
);

do $$
declare
  v_fresh_id uuid := current_setting('h6b.fresh_id')::uuid;
  v_read jsonb := current_setting('h6b.second_read')::jsonb;
begin
  if (v_read->>'id')::uuid <> v_fresh_id
     or v_read->>'status' <> 'cancelled' then
    raise exception 'FAIL h6b-backlog: terminal cancel changed conversation referent';
  end if;
end;
$$;

reset role;
select 'h6b_line_conversation_backlog_order: PASS' as result;

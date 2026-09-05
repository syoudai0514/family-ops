-- Q70/Q71: grouped LINE candidate drafts stay sender-private, support a
-- candidate-level cancellation patch, and cannot be confirmed by another
-- household member.  Execution idempotency itself remains the existing
-- pending_actions operation-id invariant and is exercised by the worker CI.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a2000000-0000-0000-0000-000000000001'),
  ('a2000000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_household jsonb;
  v_household_id uuid;
  v_pending jsonb;
  v_pending_id uuid;
  v_updated jsonb;
begin
  v_household := public.server_tx_create_household(
    'a2000000-0000-0000-0000-000000000001', gen_random_uuid(), 'LINE Multi HH', 'Owner'
  );
  v_household_id := (v_household->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_household_id, 'a2000000-0000-0000-0000-000000000002', 'adult');

  v_pending := public.server_tx_create_pending_action(
    'a2000000-0000-0000-0000-000000000001', v_household_id, gen_random_uuid(),
    'line', 'line_multi_intent_review',
    jsonb_build_object('candidates', jsonb_build_array(
      jsonb_build_object('candidate_id','c1','kind','task','title','水着を準備','status','draft','missing_fields','[]'::jsonb,'action_type','task_create_once','payload',jsonb_build_object('title','水着を準備')),
      jsonb_build_object('candidate_id','c2','kind','shopping','title','牛乳','status','draft','missing_fields','[]'::jsonb,'action_type','shopping_item_add','payload',jsonb_build_object('title','牛乳'))
    )), 30
  );
  v_pending_id := (v_pending->>'pending_action_id')::uuid;
  v_updated := public.server_tx_update_pending_action(
    'a2000000-0000-0000-0000-000000000001', v_pending_id, 'line_multi_intent_review',
    jsonb_build_object('candidates', jsonb_build_array(
      jsonb_build_object('candidate_id','c1','kind','task','title','水着を準備','status','draft','missing_fields','[]'::jsonb,'action_type','task_create_once','payload',jsonb_build_object('title','水着を準備')),
      jsonb_build_object('candidate_id','c2','kind','shopping','title','牛乳','status','cancelled','missing_fields','[]'::jsonb,'action_type','shopping_item_add','payload',jsonb_build_object('title','牛乳'))
    ))
  );
  if v_updated->'normalized_payload'->'candidates'->1->>'status' <> 'cancelled' then
    raise exception 'FAIL line-multi: only selected candidate must be cancelled';
  end if;
  begin
    perform public.server_tx_update_pending_action(
      'a2000000-0000-0000-0000-000000000002', v_pending_id, 'line_multi_intent_review', '{}'::jsonb
    );
    raise exception 'FAIL line-multi: partner must not alter sender grouped draft';
  exception when others then
    if sqlerrm <> 'PENDING_ACTION_NOT_EDITABLE' then raise; end if;
  end;
end;
$$;

reset role;
select 'line_multi_intent: PASS' as result;

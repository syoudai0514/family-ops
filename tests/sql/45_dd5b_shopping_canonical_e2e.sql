-- WP-DD5B: anyone claim/takeover, atomic purchase actual, replay safety,
-- correction, neutral intent, and test-context production isolation.

do $$
declare
  v_owner uuid := '10000000-0000-0000-0000-000000000045';
  v_partner uuid := '10000000-0000-0000-0000-000000000145';
  v_household uuid;
  v_owner_ref uuid;
  v_partner_ref uuid;
  v_item uuid;
  v_revision bigint;
  v_result jsonb;
  v_context uuid;
  v_sim_ref uuid;
  v_test_item uuid;
  v_notification_count bigint;
  v_outbox_count bigint;
  v_google_count bigint;
begin
  insert into auth.users (id) values
    (v_owner),
    (v_partner)
  on conflict (id) do nothing;
  insert into public.profiles (user_id,display_name) values
    (v_owner,'DD5B owner'),(v_partner,'DD5B partner')
  on conflict (user_id) do nothing;
  v_household := (public.server_tx_create_household(
    v_owner,'20000000-0000-0000-0000-000000000045','DD5B household','Asia/Tokyo'
  )->>'household_id')::uuid;
  insert into public.household_members (household_id,user_id,member_role,family_role)
  values (v_household,v_partner,'adult','mama');
  select id into v_owner_ref from public.domain_actor_refs
    where household_id=v_household and actor_kind='real_user' and real_user_id=v_owner;
  select id into v_partner_ref from public.domain_actor_refs
    where household_id=v_household and actor_kind='real_user' and real_user_id=v_partner;

  v_result := public.server_tx_add_shopping_item_v2(
    v_owner,'20000000-0000-0000-0000-000000000145','牛乳','store',
    'anyone',null,'avoid_duplicate',null,'2026-09-05 18:00+09'
  );
  v_item := (v_result->>'shopping_item_id')::uuid;
  v_revision := (v_result->>'revision')::bigint;

  v_result := public.server_tx_shopping_claim_v2(
    v_owner,'20000000-0000-0000-0000-000000000245',v_item,'claim',v_revision
  );
  v_revision := (v_result->>'revision')::bigint;
  v_result := public.server_tx_shopping_claim_v2(
    v_partner,'20000000-0000-0000-0000-000000000345',v_item,'takeover',v_revision
  );
  v_revision := (v_result->>'revision')::bigint;
  if (select active_claimant_actor_ref_id from public.shopping_items where id=v_item)
     is distinct from v_partner_ref then
    raise exception 'FAIL DD5B: takeover did not atomically replace claimant';
  end if;

  v_result := public.server_tx_shopping_action_v2(
    v_partner,'20000000-0000-0000-0000-000000000445',v_item,'purchased',v_revision,null
  );
  v_revision := (v_result->>'revision')::bigint;
  if not exists (
    select 1 from public.shopping_items where id=v_item and status='purchased'
      and active_claimant_actor_ref_id is null and claimed_at is null
  ) then raise exception 'FAIL DD5B: purchase did not clear claim'; end if;
  if (select count(*) from public.shopping_actual_participants
      where shopping_item_id=v_item and removed_at is null) <> 1 then
    raise exception 'FAIL DD5B: purchase actual count is not one';
  end if;
  if not exists (
    select 1 from public.user_notifications where aggregate_type='shopping'
      and aggregate_id=v_item and notification_kind='shopping.handled_neutral'
      and body='牛乳は対応済みです'
  ) then raise exception 'FAIL DD5B: neutral handled intent missing'; end if;

  -- Replaying completion must not add an actual or a second semantic event.
  perform public.server_tx_shopping_action_v2(
    v_partner,'20000000-0000-0000-0000-000000000445',v_item,'purchased',v_revision-1,null
  );
  if (select count(*) from public.shopping_actual_participants
      where shopping_item_id=v_item and removed_at is null) <> 1 then
    raise exception 'FAIL DD5B: replay duplicated actual';
  end if;

  v_result := public.server_tx_shopping_action_v2(
    v_owner,'20000000-0000-0000-0000-000000000545',v_item,'reopen',v_revision,
    '購入登録を取り消す'
  );
  if (select status from public.shopping_items where id=v_item) <> 'wanted'
     or exists (select 1 from public.shopping_actual_participants
                where shopping_item_id=v_item and removed_at is null) then
    raise exception 'FAIL DD5B: correction did not restore actionable truth';
  end if;
  if not exists (
    select 1 from public.user_notifications where aggregate_type='shopping'
      and aggregate_id=v_item and notification_kind='shopping.reopened_neutral'
      and body='牛乳は未対応に戻りました'
  ) then raise exception 'FAIL DD5B: neutral correction intent missing'; end if;

  select count(*) into v_notification_count from public.user_notifications;
  select count(*) into v_outbox_count from private.notification_outbox;
  select count(*) into v_google_count from private.google_write_operations;

  insert into public.test_simulation_contexts (household_id,operator_user_id,label)
  values (v_household,v_owner,'DD5B test') returning id into v_context;
  insert into public.domain_actor_refs (
    household_id,actor_kind,test_context_id,simulated_role
  ) values (v_household,'simulated_member',v_context,'mama') returning id into v_sim_ref;

  v_result := private.fn_command_create_shopping_item_v1(
    v_household,v_owner,v_sim_ref,v_context,'テストの薬','store','anyone',null,
    'safety_critical',null,null,'20000000-0000-0000-0000-000000000645','line'
  );
  v_test_item := (v_result->>'shopping_item_id')::uuid;
  v_result := private.fn_command_shopping_claim_v1(
    v_household,v_owner,v_sim_ref,v_context,v_test_item,'claim',1,
    '20000000-0000-0000-0000-000000000745','line'
  );
  perform private.fn_command_complete_shopping_item_v1(
    v_household,v_owner,v_sim_ref,v_context,v_test_item,'purchased',v_sim_ref,
    (v_result->>'revision')::bigint,'20000000-0000-0000-0000-000000000845','line'
  );
  if not exists (
    select 1 from public.shopping_actual_participants
    where shopping_item_id=v_test_item and actor_ref_id=v_sim_ref
      and recorded_by_actor_ref_id=v_sim_ref and test_context_id=v_context
  ) then raise exception 'FAIL DD5B: simulated performer/recorder not preserved'; end if;
  if (select count(*) from public.user_notifications) <> v_notification_count
     or (select count(*) from private.notification_outbox) <> v_outbox_count
     or (select count(*) from private.google_write_operations) <> v_google_count then
    raise exception 'FAIL DD5B: test Shopping leaked to production side effects';
  end if;
  if not exists (
    select 1 from private.test_delivery_outbox
    where test_context_id=v_context and rendered_payload->>'notification_kind'='shopping.handled_neutral'
      and rendered_payload->>'text' like '🧪%'
  ) then raise exception 'FAIL DD5B: synthetic neutral handled delivery missing marker'; end if;
  if (public.server_read_shopping_workspace(v_owner)->'active') @> jsonb_build_array(
    jsonb_build_object('shopping_item_id',v_test_item)
  ) then raise exception 'FAIL DD5B: test Shopping leaked into production reader'; end if;
end;
$$;

select 'PASS WP-DD5B canonical Shopping E2E' as result;

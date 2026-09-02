-- WP-DD5B / WP-DD6 / WP-DD7 R0 foundation invariants.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('39000000-0000-0000-0000-000000000001'),
  ('39000000-0000-0000-0000-000000000002')
on conflict do nothing;

set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_owner_actor uuid;
  v_partner_actor uuid;
  v_test_context uuid;
  v_sim_actor uuid;
  v_item_id uuid;
  v_test_item_id uuid;
  v_google_connection_id uuid;
  v_calendar_connection_id uuid;
  v_brief jsonb;
  v_policy jsonb;
begin
  v_hh := public.server_tx_create_household(
    '39000000-0000-0000-0000-000000000001',
    gen_random_uuid(),
    'DD5B-DD7 HH',
    'Owner'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;

  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, '39000000-0000-0000-0000-000000000002', 'adult');

  insert into public.domain_actor_refs (household_id, actor_kind, real_user_id)
  values (v_hh_id, 'real_user', '39000000-0000-0000-0000-000000000001')
  returning id into v_owner_actor;

  insert into public.domain_actor_refs (household_id, actor_kind, real_user_id)
  values (v_hh_id, 'real_user', '39000000-0000-0000-0000-000000000002')
  returning id into v_partner_actor;

  -- DD6 cadence representation: all three canonical kinds fit alongside the
  -- legacy nine kinds before atomic cutover.
  insert into public.household_routine_schedules
    (household_id, schedule_kind, local_time, enabled, updated_by)
  values
    (v_hh_id, 'daily_brief_weekday_morning', time '06:30', true,
      '39000000-0000-0000-0000-000000000001'),
    (v_hh_id, 'daily_brief_nonworkday_morning', time '09:00', true,
      '39000000-0000-0000-0000-000000000001'),
    (v_hh_id, 'daily_brief_evening', time '20:30', true,
      '39000000-0000-0000-0000-000000000001');

  if (select local_time from public.household_routine_schedules
      where household_id = v_hh_id and schedule_kind = 'daily_brief_weekday_morning')
      <> time '06:30' then
    raise exception 'FAIL DD6: weekday morning base time must persist as 06:30';
  end if;
  if (select local_time from public.household_routine_schedules
      where household_id = v_hh_id and schedule_kind = 'daily_brief_nonworkday_morning')
      <> time '09:00' then
    raise exception 'FAIL DD6: non-workday morning base time must persist as 09:00';
  end if;
  if (select local_time from public.household_routine_schedules
      where household_id = v_hh_id and schedule_kind = 'daily_brief_evening')
      <> time '20:30' then
    raise exception 'FAIL DD6: evening base time must persist as 20:30';
  end if;

  insert into public.daily_brief_schedule_overrides
    (household_id, local_date, schedule_kind, enabled, local_time, updated_by)
  values
    (v_hh_id, date '2030-01-02', 'daily_brief_weekday_morning', true, time '07:15',
      '39000000-0000-0000-0000-000000000001'),
    (v_hh_id, date '2030-01-03', 'daily_brief_evening', false, null,
      '39000000-0000-0000-0000-000000000001');

  begin
    insert into public.daily_brief_schedule_overrides
      (household_id, local_date, schedule_kind, enabled, local_time, updated_by)
    values
      (v_hh_id, date '2030-01-04', 'daily_brief_evening', true, null,
        '39000000-0000-0000-0000-000000000001');
    raise exception 'FAIL DD6: enabled one-day override must require local_time';
  exception
    when check_violation then null;
  end;

  -- DD7 policy: normal completion never creates an immediate praise push.
  v_policy := private.resolve_notification_policy(
    p_semantic_type => 'task_completed',
    p_duplicate_sensitivity => 'normal'
  );
  if v_policy->>'disposition' <> 'in_app_only'
     or v_policy->>'reason' <> 'normal_completion_no_immediate_push' then
    raise exception 'FAIL DD7: normal completion policy mismatch: %', v_policy;
  end if;

  -- Duplicate-sensitive completion changes partner behavior neutrally and can
  -- be immediate; quota denial degrades to in-app without falsifying sent.
  v_policy := private.resolve_notification_policy(
    p_semantic_type => 'shopping_completed',
    p_duplicate_sensitivity => 'avoid_duplicate',
    p_behavior_change_now => true
  );
  if v_policy->>'disposition' <> 'immediate' then
    raise exception 'FAIL DD7: duplicate-sensitive completion should be immediate: %', v_policy;
  end if;

  v_policy := private.resolve_notification_policy(
    p_semantic_type => 'shopping_completed',
    p_duplicate_sensitivity => 'avoid_duplicate',
    p_behavior_change_now => true,
    p_line_quota_allows_push => false
  );
  if v_policy->>'disposition' <> 'in_app_only'
     or v_policy->>'reason' <> 'line_quota_preserved' then
    raise exception 'FAIL DD7: quota protection mismatch: %', v_policy;
  end if;

  v_policy := private.resolve_notification_policy(
    p_semantic_type => 'waiting_check_due',
    p_attention_state => 'waiting',
    p_next_check_at => now() + interval '1 day'
  );
  if v_policy->>'disposition' <> 'suppressed'
     or v_policy->>'reason' <> 'waiting_before_next_check' then
    raise exception 'FAIL DD7: waiting task nagged before next check: %', v_policy;
  end if;

  v_policy := private.resolve_notification_policy(
    p_semantic_type => 'waiting_check_due',
    p_attention_state => 'waiting',
    p_next_check_at => now() - interval '1 minute'
  );
  if v_policy->>'disposition' <> 'next_digest' then
    raise exception 'FAIL DD7: due waiting check should surface in digest: %', v_policy;
  end if;

  v_policy := private.resolve_notification_policy(
    p_semantic_type => 'request_created',
    p_reply_or_action_required => true,
    p_test_context_id => gen_random_uuid()
  );
  if v_policy->>'disposition' <> 'suppressed'
     or v_policy->>'reason' <> 'test_context_production_delivery_forbidden' then
    raise exception 'FAIL DD3A/DD7: test context must never select production delivery: %', v_policy;
  end if;

  v_policy := private.resolve_notification_policy(
    p_semantic_type => 'request_created',
    p_reply_or_action_required => true,
    p_is_stale => true
  );
  if v_policy->>'disposition' <> 'suppressed'
     or v_policy->>'reason' <> 'stale_intent' then
    raise exception 'FAIL DD7: stale intent must be suppressed: %', v_policy;
  end if;

  -- DD5B evidence: a production item can record a real ActorRef performer.
  v_item_id := (public.server_tx_add_shopping_item(
    '39000000-0000-0000-0000-000000000001',
    gen_random_uuid(),
    'Milk',
    'either',
    null,
    null,
    null
  )->>'shopping_item_id')::uuid;

  insert into public.shopping_actual_participants
    (household_id, shopping_item_id, actor_ref_id, recorded_by_actor_ref_id)
  values (v_hh_id, v_item_id, v_owner_actor, v_owner_actor);

  if (select count(*) from public.shopping_actual_participants
      where shopping_item_id = v_item_id and removed_at is null) <> 1 then
    raise exception 'FAIL DD5B: production actual performer evidence missing';
  end if;

  -- A simulated ActorRef can never leak into a production shopping row.
  insert into public.test_simulation_contexts
    (household_id, operator_user_id, label)
  values (v_hh_id, '39000000-0000-0000-0000-000000000001', 'DD5B sandbox')
  returning id into v_test_context;

  insert into public.domain_actor_refs
    (household_id, actor_kind, test_context_id, simulated_role)
  values (v_hh_id, 'simulated_member', v_test_context, 'mama')
  returning id into v_sim_actor;

  begin
    insert into public.shopping_actual_participants
      (household_id, shopping_item_id, actor_ref_id, recorded_by_actor_ref_id)
    values (v_hh_id, v_item_id, v_sim_actor, v_sim_actor);
    raise exception 'FAIL DD5B: simulated performer leaked into production shopping';
  exception
    when others then
      if sqlerrm <> 'SIMULATED_ACTOR_IN_PRODUCTION_ROW' then
        raise exception 'FAIL DD5B: expected SIMULATED_ACTOR_IN_PRODUCTION_ROW, got %', sqlerrm;
      end if;
  end;

  -- Same simulated actor is valid on a directly test-scoped shopping item.
  insert into public.shopping_items (
    household_id, title, purchase_method, status, assignee_id, url, due_at,
    created_by, test_context_id, assignment_mode, duplicate_sensitivity
  ) values (
    v_hh_id, 'Sandbox milk', 'either', 'wanted', null, null, null,
    '39000000-0000-0000-0000-000000000001', v_test_context, 'anyone', 'avoid_duplicate'
  ) returning id into v_test_item_id;

  insert into public.shopping_actual_participants (
    household_id, shopping_item_id, actor_ref_id, recorded_by_actor_ref_id, test_context_id
  ) values (v_hh_id, v_test_item_id, v_sim_actor, v_sim_actor, v_test_context);

  -- DD6 all-day rendering: store an actual Google all-day occurrence.  The
  -- DailyBrief must preserve dates and return JSON null for timestamps.
  insert into private.google_connections (
    household_id, owner_user_id, google_subject, encrypted_refresh_token,
    encryption_version, scopes, status
  ) values (
    v_hh_id,
    '39000000-0000-0000-0000-000000000001',
    'dd6-subject',
    'ciphertext',
    1,
    array['calendar.readonly'],
    'active'
  ) returning id into v_google_connection_id;

  insert into public.calendar_connections (
    household_id, external_calendar_id, display_name, google_connection_id, active
  ) values (
    v_hh_id, 'dd6-calendar', 'DD6 calendar', v_google_connection_id, true
  ) returning id into v_calendar_connection_id;

  insert into public.calendar_event_occurrences (
    household_id, calendar_connection_id, occurrence_key, google_event_id,
    title, starts_at, ends_at, all_day_start, all_day_end_exclusive,
    status, transparency, projection_window_start, projection_window_end
  ) values (
    v_hh_id, v_calendar_connection_id, 'all-day-1', 'event-all-day-1',
    'School holiday', null, null, date '2030-01-02', date '2030-01-03',
    'confirmed', 'opaque', date '2030-01-01', date '2030-01-10'
  );

  v_brief := public.server_read_daily_brief(
    '39000000-0000-0000-0000-000000000001',
    date '2030-01-02'
  );

  if v_brief->>'local_date' <> '2030-01-02' then
    raise exception 'FAIL DD6: DailyBrief local_date mismatch: %', v_brief->>'local_date';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(v_brief->'schedule') e
    where e->>'occurrence_key' = 'all-day-1'
      and (e->>'is_all_day')::boolean
      and e->'starts_at' = 'null'::jsonb
      and e->'ends_at' = 'null'::jsonb
      and e->>'all_day_start' = '2030-01-02'
  ) then
    raise exception 'FAIL DD6: all-day occurrence missing or fake timestamp introduced: %', v_brief->'schedule';
  end if;

  -- Production DailyBrief must exclude directly test-scoped shopping rows.
  if exists (
    select 1
    from jsonb_array_elements(v_brief->'shopping') e
    where e->>'shopping_item_id' = v_test_item_id::text
  ) then
    raise exception 'FAIL DD5B/DD6: test shopping leaked into production DailyBrief';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(v_brief->'shopping') e
    where e->>'shopping_item_id' = v_item_id::text
  ) then
    raise exception 'FAIL DD5B/DD6: production shopping missing from DailyBrief';
  end if;
end;
$$;

reset role;
select 'dd5b_dd6_dd7_read_policy_foundation: PASS' as result;

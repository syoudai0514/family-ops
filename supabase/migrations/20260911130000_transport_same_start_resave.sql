-- F2 real-use remediation: saving a transport "life pattern" again on the
-- same start date is an edit, not an internal error. Preserve one period row,
-- update its seven-day matrix/rules in place, and keep protected one-off
-- occurrences untouched.

create or replace function public.server_tx_update_transport_template_same_start_v1(
  p_actor_id uuid,
  p_operation_id uuid,
  p_valid_from date,
  p_days jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref uuid;
  v_claim jsonb;
  v_receipt_id uuid;
  v_template public.transport_weekly_templates%rowtype;
  v_template_id uuid;
  v_day jsonb;
  v_weekday int;
  v_dropoff uuid;
  v_pickup uuid;
  v_dropoff_time time;
  v_pickup_time time;
  v_dropoff_def uuid;
  v_pickup_def uuid;
  v_rule public.recurrence_rules%rowtype;
  v_horizon_end date;
  v_conflicts jsonb;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_valid_from is null
     or jsonb_typeof(p_days) <> 'array' or jsonb_array_length(p_days) <> 7 then
    raise exception 'TRANSPORT_TEMPLATE_INVALID';
  end if;
  if (
    select count(distinct (value->>'weekday')::int)
    from jsonb_array_elements(p_days)
  ) <> 7
  or exists(
    select 1
    from jsonb_array_elements(p_days) x
    where (x->>'weekday')::int not between 1 and 7
  ) then
    raise exception 'TRANSPORT_TEMPLATE_WEEK_INVALID';
  end if;

  -- Editing a historical closed period would rewrite history. The PWA starts
  -- edits from today, so same-start replacement is limited to today/future.
  if p_valid_from < (now() at time zone 'Asia/Tokyo')::date then
    raise exception 'TRANSPORT_TEMPLATE_PAST_UPDATE';
  end if;

  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;
  v_actor_ref := (v_context->>'actor_ref_id')::uuid;

  v_claim := private.fn_claim_canonical_operation_v1(
    v_household_id,
    p_actor_id,
    v_actor_ref,
    null,
    p_operation_id,
    'transport.template.update_same_start',
    private.fn_canonical_request_hash_v1(
      jsonb_build_object('valid_from', p_valid_from, 'days', p_days)
    )
  );
  if v_claim->>'disposition' = 'replay' then
    return v_claim->'result_payload';
  end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  perform pg_advisory_xact_lock(hashtext('transport-template:' || v_household_id::text));

  select *
    into v_template
  from public.transport_weekly_templates
  where household_id = v_household_id
    and valid_from = p_valid_from
  for update;

  if not found then
    raise exception 'TRANSPORT_TEMPLATE_NOT_FOUND';
  end if;
  v_template_id := v_template.id;

  for v_day in select value from jsonb_array_elements(p_days) loop
    v_dropoff := nullif(v_day->>'dropoff_user_id','')::uuid;
    v_pickup := nullif(v_day->>'pickup_user_id','')::uuid;
    if v_dropoff is not null and not exists(
      select 1 from public.household_members
      where household_id = v_household_id and user_id = v_dropoff
    ) then
      raise exception 'CROSS_HOUSEHOLD_RESOURCE';
    end if;
    if v_pickup is not null and not exists(
      select 1 from public.household_members
      where household_id = v_household_id and user_id = v_pickup
    ) then
      raise exception 'CROSS_HOUSEHOLD_RESOURCE';
    end if;
  end loop;

  -- Replace the visible seven-day matrix in place.
  for v_day in select value from jsonb_array_elements(p_days) loop
    v_weekday := (v_day->>'weekday')::int;
    v_dropoff := nullif(v_day->>'dropoff_user_id','')::uuid;
    v_pickup := nullif(v_day->>'pickup_user_id','')::uuid;
    v_dropoff_time := nullif(v_day->>'dropoff_local_time','')::time;
    v_pickup_time := nullif(v_day->>'pickup_local_time','')::time;

    insert into public.transport_weekly_template_days(
      household_id,
      template_id,
      weekday,
      dropoff_user_id,
      pickup_user_id,
      dropoff_local_time,
      pickup_local_time
    ) values(
      v_household_id,
      v_template_id,
      v_weekday,
      v_dropoff,
      v_pickup,
      v_dropoff_time,
      v_pickup_time
    )
    on conflict(template_id,weekday) do update set
      dropoff_user_id = excluded.dropoff_user_id,
      pickup_user_id = excluded.pickup_user_id,
      dropoff_local_time = excluded.dropoff_local_time,
      pickup_local_time = excluded.pickup_local_time;
  end loop;

  select id into v_dropoff_def
  from public.task_definitions
  where household_id = v_household_id and code = 'dropoff';

  select id into v_pickup_def
  from public.task_definitions
  where household_id = v_household_id and code = 'pickup';

  if v_dropoff_def is null or v_pickup_def is null then
    raise exception 'TRANSPORT_DEFINITIONS_REQUIRED';
  end if;

  -- Keep rule ids stable when a rule already exists. If a leg changes from
  -- "none" to a person, create a new active rule; if it changes to "none",
  -- deactivate the current rule. Exclusion constraints apply only to active
  -- rules, so this does not create overlapping periods.
  for v_day in select value from jsonb_array_elements(p_days) loop
    v_weekday := (v_day->>'weekday')::int;

    -- Dropoff.
    v_dropoff := nullif(v_day->>'dropoff_user_id','')::uuid;
    v_dropoff_time := nullif(v_day->>'dropoff_local_time','')::time;
    select * into v_rule
    from public.recurrence_rules
    where household_id = v_household_id
      and transport_template_id = v_template_id
      and task_definition_id = v_dropoff_def
      and weekday = v_weekday
      and transport_leg = 'dropoff'
      and active
    order by version desc, updated_at desc, id desc
    limit 1
    for update;

    if v_dropoff is null then
      if v_rule.id is not null then
        update public.recurrence_rules
        set active = false,
            version = version + 1
        where id = v_rule.id;
      end if;
    elsif v_rule.id is not null then
      update public.recurrence_rules
      set assignee_strategy = 'fixed',
          planned_assignee_id = v_dropoff,
          scheduled_local_time = v_dropoff_time,
          effective_from = p_valid_from,
          effective_to = v_template.valid_to,
          active = true,
          version = version + 1
      where id = v_rule.id;
    else
      insert into public.recurrence_rules(
        household_id,
        task_definition_id,
        weekday,
        slot_key,
        assignee_strategy,
        planned_assignee_id,
        scheduled_local_time,
        effective_from,
        effective_to,
        active,
        version,
        created_by,
        transport_template_id,
        transport_leg
      ) values(
        v_household_id,
        v_dropoff_def,
        v_weekday,
        'default',
        'fixed',
        v_dropoff,
        v_dropoff_time,
        p_valid_from,
        v_template.valid_to,
        true,
        1,
        p_actor_id,
        v_template_id,
        'dropoff'
      );
    end if;

    -- Pickup.
    v_pickup := nullif(v_day->>'pickup_user_id','')::uuid;
    v_pickup_time := nullif(v_day->>'pickup_local_time','')::time;
    select * into v_rule
    from public.recurrence_rules
    where household_id = v_household_id
      and transport_template_id = v_template_id
      and task_definition_id = v_pickup_def
      and weekday = v_weekday
      and transport_leg = 'pickup'
      and active
    order by version desc, updated_at desc, id desc
    limit 1
    for update;

    if v_pickup is null then
      if v_rule.id is not null then
        update public.recurrence_rules
        set active = false,
            version = version + 1
        where id = v_rule.id;
      end if;
    elsif v_rule.id is not null then
      update public.recurrence_rules
      set assignee_strategy = 'fixed',
          planned_assignee_id = v_pickup,
          scheduled_local_time = v_pickup_time,
          effective_from = p_valid_from,
          effective_to = v_template.valid_to,
          active = true,
          version = version + 1
      where id = v_rule.id;
    else
      insert into public.recurrence_rules(
        household_id,
        task_definition_id,
        weekday,
        slot_key,
        assignee_strategy,
        planned_assignee_id,
        scheduled_local_time,
        effective_from,
        effective_to,
        active,
        version,
        created_by,
        transport_template_id,
        transport_leg
      ) values(
        v_household_id,
        v_pickup_def,
        v_weekday,
        'default',
        'fixed',
        v_pickup,
        v_pickup_time,
        p_valid_from,
        v_template.valid_to,
        true,
        1,
        p_actor_id,
        v_template_id,
        'pickup'
      );
    end if;
  end loop;

  -- Re-project only rule-derived, unprotected occurrences. Explicit one-off
  -- agreements, overrides, cancellations and completed/skipped work remain
  -- untouched exactly as in the original save command.
  with candidates as (
    select
      ti.id,
      nr.id as new_rule_id,
      nr.planned_assignee_id as new_user_id,
      nr.scheduled_local_time,
      ar.id as new_actor_ref
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id = ti.household_id
     and td.id = ti.task_definition_id
    left join public.recurrence_rules nr
      on nr.household_id = ti.household_id
     and nr.transport_template_id = v_template_id
     and nr.task_definition_id = ti.task_definition_id
     and nr.weekday = extract(isodow from ti.scheduled_date)::smallint
     and nr.active
    left join public.domain_actor_refs ar
      on ar.household_id = ti.household_id
     and ar.actor_kind = 'real_user'
     and ar.real_user_id = nr.planned_assignee_id
    where ti.household_id = v_household_id
      and td.code in ('dropoff','pickup')
      and ti.origin = 'recurring'
      and ti.scheduled_date >= p_valid_from
      and (v_template.valid_to is null or ti.scheduled_date <= v_template.valid_to)
      and ti.status in ('todo','in_progress','cancelled')
      and coalesce(ti.assignment_source,'legacy_snapshot') = 'legacy_snapshot'
      and not (ti.source_context ? 'transport_occurrence_override')
      and not exists(
        select 1
        from public.task_events e
        where e.household_id = ti.household_id
          and e.task_instance_id = ti.id
          and e.event_type in ('reassigned_once','cancelled')
      )
  )
  update public.task_instances ti
  set recurrence_rule_id = c.new_rule_id,
      planned_assignee_id = c.new_user_id,
      planned_assignee_actor_ref_id = c.new_actor_ref,
      assignment_mode = case when c.new_user_id is null then 'unassigned' else 'person' end,
      assignment_source = 'legacy_snapshot',
      due_at = case
        when c.scheduled_local_time is null then null
        else ((ti.scheduled_date::text || ' ' || c.scheduled_local_time::text)::timestamp at time zone 'Asia/Tokyo')
      end,
      status = case
        when c.new_rule_id is null then 'cancelled'
        when ti.status = 'cancelled' then 'todo'
        else ti.status
      end,
      revision = ti.revision + 1
  from candidates c
  where ti.id = c.id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',ti.id,
    'date',ti.scheduled_date,
    'leg',td.code,
    'planned_assignee_user_id',ti.planned_assignee_id,
    'assignment_source',ti.assignment_source
  ) order by ti.scheduled_date,td.code),'[]'::jsonb)
  into v_conflicts
  from public.task_instances ti
  join public.task_definitions td
    on td.household_id = ti.household_id
   and td.id = ti.task_definition_id
  where ti.household_id = v_household_id
    and td.code in ('dropoff','pickup')
    and ti.scheduled_date >= p_valid_from
    and (v_template.valid_to is null or ti.scheduled_date <= v_template.valid_to)
    and ti.status in ('todo','in_progress','completed','skipped','cancelled')
    and (
      coalesce(ti.assignment_source,'legacy_snapshot') <> 'legacy_snapshot'
      or ti.source_context ? 'transport_occurrence_override'
      or exists(
        select 1
        from public.task_events e
        where e.household_id = ti.household_id
          and e.task_instance_id = ti.id
          and e.event_type in ('reassigned_once','cancelled')
      )
    );

  v_horizon_end := least(
    coalesce(v_template.valid_to, ((now() at time zone 'Asia/Tokyo')::date + 90)),
    ((now() at time zone 'Asia/Tokyo')::date + 90)
  );

  if p_valid_from <= v_horizon_end then
    for v_rule in
      select *
      from public.recurrence_rules
      where household_id = v_household_id
        and transport_template_id = v_template_id
        and active
    loop
      perform private.materialize_recurrence_rule(
        v_household_id,
        v_rule.id,
        greatest(p_valid_from, (now() at time zone 'Asia/Tokyo')::date),
        v_horizon_end
      );
    end loop;
  end if;

  update public.transport_weekly_templates
  set revision = revision + 1
  where id = v_template_id
  returning * into v_template;

  v_result := jsonb_build_object(
    'template_id', v_template_id,
    'valid_from', p_valid_from,
    'valid_to', v_template.valid_to,
    'revision', v_template.revision,
    'updated_existing', true,
    'protected_conflicts', v_conflicts
  );

  perform private.fn_complete_canonical_operation_v1(
    v_receipt_id,
    'transport_weekly_template',
    v_template_id,
    v_result
  );
  return v_result;
end;
$$;

revoke all on function public.server_tx_update_transport_template_same_start_v1(uuid,uuid,date,jsonb)
  from public, anon, authenticated;
grant execute on function public.server_tx_update_transport_template_same_start_v1(uuid,uuid,date,jsonb)
  to service_role;

create or replace function public.server_tx_save_transport_template_v2(
  p_actor_id uuid,
  p_operation_id uuid,
  p_valid_from date,
  p_days jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_result jsonb;
  v_group uuid;
  v_template uuid;
  v_conf jsonb;
  v_count int := 0;
  v_member record;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;

  if exists(
    select 1
    from public.transport_weekly_templates
    where household_id = v_household_id
      and valid_from = p_valid_from
  ) then
    v_result := public.server_tx_update_transport_template_same_start_v1(
      p_actor_id, p_operation_id, p_valid_from, p_days
    );
  else
    v_result := public.server_tx_save_transport_template(
      p_actor_id, p_operation_id, p_valid_from, p_days
    );
  end if;

  v_template := (v_result->>'template_id')::uuid;
  v_count := jsonb_array_length(coalesce(v_result->'protected_conflicts','[]'::jsonb));

  if v_count > 0 then
    insert into public.transport_conflict_review_groups(
      household_id, template_id, created_by
    ) values(
      v_household_id, v_template, p_actor_id
    )
    on conflict(template_id) do update set
      created_by = excluded.created_by,
      status = 'pending',
      resolved_at = null,
      revision = public.transport_conflict_review_groups.revision + 1
    returning id into v_group;

    delete from public.transport_conflict_review_responses
    where group_id = v_group;
    delete from public.transport_conflict_review_items
    where group_id = v_group;

    for v_conf in
      select value
      from jsonb_array_elements(v_result->'protected_conflicts')
    loop
      insert into public.transport_conflict_review_items(
        group_id, household_id, task_instance_id, occurrence_date, leg
      ) values(
        v_group,
        v_household_id,
        (v_conf->>'task_id')::uuid,
        (v_conf->>'date')::date,
        v_conf->>'leg'
      )
      on conflict do nothing;
    end loop;

    for v_member in
      select user_id
      from public.household_members
      where household_id = v_household_id
    loop
      insert into public.user_notifications(
        household_id,
        recipient_user_id,
        type,
        title,
        body,
        payload,
        dedup_key
      ) values(
        v_household_id,
        v_member.user_id,
        'transport_conflict_review',
        '個別の送り迎え予定を確認',
        '生活パターン変更後も個別合意は維持しています。維持するか見直すか確認してください。',
        jsonb_build_object('review_group_id',v_group,'template_id',v_template),
        'transport-conflict-review:' || v_group::text
      )
      on conflict(recipient_user_id,dedup_key) do nothing;
    end loop;

    v_result := v_result || jsonb_build_object(
      'conflict_review_group_id', v_group,
      'confirmation_required', true
    );
  else
    update public.transport_conflict_review_groups
    set status = 'kept',
        resolved_at = now(),
        revision = revision + 1
    where template_id = v_template
      and status in ('pending','needs_review');
  end if;

  return v_result;
end;
$$;

revoke all on function public.server_tx_save_transport_template_v2(uuid,uuid,date,jsonb)
  from public, anon, authenticated;
grant execute on function public.server_tx_save_transport_template_v2(uuid,uuid,date,jsonb)
  to service_role;

-- WP-DD5 / WP-DD5B: inactive canonical result/history readers.
--
-- These are service-role read models only. They do not activate Task or
-- Shopping command writers and therefore do not cross either aggregate's P1.
-- They make the accepted result semantics executable now:
--   * explicit outcome_reason distinguishes not-needed / could-not-do / expiry
--   * waiting is orthogonal to failure
--   * unknown/open evidence is never guessed into failure
--   * multiple performers are preserved, while one completed household item
--     contributes exactly one completion unit
--   * direct test-context rows are excluded from production history/analytics

create or replace function public.server_read_task_result_history(
  p_actor_id uuid,
  p_since_local_date date default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_since date := coalesce(p_since_local_date, (now() at time zone 'Asia/Tokyo')::date - 14);
  v_result jsonb;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id', ti.id,
    'title', ti.title,
    'scheduled_date', ti.scheduled_date,
    'due_at', ti.due_at,
    'status', ti.status,
    'attention_state', ti.attention_state,
    'waiting_note', ti.waiting_note,
    'next_check_at', ti.next_check_at,
    'outcome_reason', ti.outcome_reason,
    'semantic_result', case
      when ti.status = 'completed' then 'completed'
      when ti.status = 'skipped' and ti.outcome_reason = 'not_needed_this_occurrence' then 'not_needed'
      when ti.status = 'skipped' and ti.outcome_reason = 'could_not_do' then 'could_not_do'
      when ti.status = 'skipped' and ti.outcome_reason = 'expired_occurrence' then 'expired_occurrence'
      when ti.status = 'cancelled' then 'cancelled'
      when ti.attention_state = 'waiting' then 'waiting'
      when ti.status in ('todo', 'in_progress') then 'open_or_unknown'
      else 'unknown'
    end,
    'result_certainty', case
      when ti.status = 'completed' then 'confirmed'
      when ti.status = 'skipped' and ti.outcome_reason is not null then 'confirmed'
      when ti.status = 'cancelled' then 'confirmed'
      when ti.attention_state = 'waiting' then 'known_waiting'
      else 'unknown'
    end,
    'performer_count', coalesce(actuals.performer_count, 0),
    'performers', coalesce(actuals.performers, '[]'::jsonb),
    'household_completion_units', case when ti.status = 'completed' then 1 else 0 end,
    'revision', ti.revision,
    'action_target', jsonb_build_object('kind', 'task', 'task_id', ti.id, 'revision', ti.revision)
  ) order by ti.scheduled_date desc, ti.due_at desc nulls last, ti.created_at desc), '[]'::jsonb)
  into v_result
  from public.task_instances ti
  left join lateral (
    select
      count(*)::int as performer_count,
      jsonb_agg(jsonb_build_object(
        'actor_ref_id', tap.actor_ref_id,
        'real_user_id', ar.real_user_id,
        'actor_kind', ar.actor_kind,
        'simulated_role', ar.simulated_role,
        'recorded_at', tap.recorded_at,
        'recorded_by_actor_ref_id', tap.recorded_by_actor_ref_id
      ) order by tap.recorded_at, tap.id) as performers
    from public.task_actual_participants tap
    join public.domain_actor_refs ar
      on ar.household_id = tap.household_id and ar.id = tap.actor_ref_id
    where tap.household_id = ti.household_id
      and tap.task_instance_id = ti.id
      and tap.test_context_id is null
      and tap.removed_at is null
  ) actuals on true
  where ti.household_id = v_household_id
    and ti.test_context_id is null
    and ti.scheduled_date >= v_since;

  return jsonb_build_object(
    'generated_at', now(),
    'household_id', v_household_id,
    'since_local_date', v_since,
    'items', v_result
  );
end;
$$;

revoke all on function public.server_read_task_result_history(uuid, date)
  from public, anon, authenticated;
grant execute on function public.server_read_task_result_history(uuid, date) to service_role;

create or replace function public.server_read_shopping_workspace(
  p_actor_id uuid
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_active jsonb;
  v_history jsonb;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select id into v_actor_ref_id
  from public.domain_actor_refs
  where household_id = v_household_id
    and actor_kind = 'real_user'
    and real_user_id = p_actor_id;

  with shaped as (
    select
      si.*,
      coalesce(actuals.performer_count, 0) as performer_count,
      coalesce(actuals.performers, '[]'::jsonb) as performers,
      jsonb_build_object(
        'shopping_item_id', si.id,
        'title', si.title,
        'purchase_method', si.purchase_method,
        'status', si.status,
        'due_at', si.due_at,
        'assignment_mode', coalesce(si.assignment_mode,
          case when si.assignee_id is null then 'unassigned' else 'person' end),
        'assignee_actor_ref_id', si.assignee_actor_ref_id,
        'active_claimant_actor_ref_id', si.active_claimant_actor_ref_id,
        'claimed_at', si.claimed_at,
        'duplicate_sensitivity', coalesce(si.duplicate_sensitivity, 'normal'),
        'performer_count', coalesce(actuals.performer_count, 0),
        'performers', coalesce(actuals.performers, '[]'::jsonb),
        'household_completion_units', case
          when si.status in ('purchased', 'arrived') then 1 else 0 end,
        'revision', si.revision,
        'action_target', jsonb_build_object(
          'kind', 'shopping', 'shopping_item_id', si.id, 'revision', si.revision
        )
      ) as item
    from public.shopping_items si
    left join lateral (
      select
        count(*)::int as performer_count,
        jsonb_agg(jsonb_build_object(
          'actor_ref_id', sap.actor_ref_id,
          'real_user_id', ar.real_user_id,
          'actor_kind', ar.actor_kind,
          'simulated_role', ar.simulated_role,
          'recorded_at', sap.recorded_at,
          'recorded_by_actor_ref_id', sap.recorded_by_actor_ref_id
        ) order by sap.recorded_at, sap.id) as performers
      from public.shopping_actual_participants sap
      join public.domain_actor_refs ar
        on ar.household_id = sap.household_id and ar.id = sap.actor_ref_id
      where sap.household_id = si.household_id
        and sap.shopping_item_id = si.id
        and sap.test_context_id is null
        and sap.removed_at is null
    ) actuals on true
    where si.household_id = v_household_id
      and si.test_context_id is null
  )
  select
    coalesce(jsonb_agg(item order by due_at nulls last, created_at)
      filter (where status in ('wanted', 'assigned', 'ordered')), '[]'::jsonb),
    coalesce(jsonb_agg(item order by coalesce(arrived_at, purchased_at, ordered_at, created_at) desc)
      filter (where status in ('purchased', 'arrived', 'cancelled')), '[]'::jsonb)
  into v_active, v_history
  from shaped;

  return jsonb_build_object(
    'generated_at', now(),
    'household_id', v_household_id,
    'actor_ref_id', v_actor_ref_id,
    'active', v_active,
    'history', v_history
  );
end;
$$;

revoke all on function public.server_read_shopping_workspace(uuid)
  from public, anon, authenticated;
grant execute on function public.server_read_shopping_workspace(uuid) to service_role;

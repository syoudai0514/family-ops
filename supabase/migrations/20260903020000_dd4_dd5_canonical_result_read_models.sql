-- WP-DD4 / WP-DD5 parallel worker read models.
--
-- These functions are read-only and service-role-only. They deliberately do not
-- activate any PWA/LINE reader or writer, and therefore do not cross P1.
-- Command ownership remains in WP-DD3. In particular, post-accept change/cancel
-- Attempt creation is readable here but is not invented by this migration.

create or replace function public.server_read_request_workspace(
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
  v_incoming jsonb;
  v_outgoing jsonb;
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

  with request_rows as (
    select
      r.*,
      latest.id as latest_attempt_id,
      latest.attempt_kind as latest_attempt_kind,
      latest.state as latest_attempt_state,
      latest.terms_revision as latest_terms_revision,
      latest.terms as latest_terms,
      latest.reply_due_at as latest_reply_due_at,
      latest.revision as latest_attempt_revision,
      agreement.id as agreement_attempt_id,
      agreement.accepted_at as agreement_accepted_at,
      agreement.terms_revision as agreement_terms_revision,
      agreement.terms as agreement_terms,
      ti.status as execution_task_status,
      ti.scheduled_date as execution_task_scheduled_date,
      ti.due_at as execution_task_due_at,
      ti.completed_at as execution_task_completed_at,
      ti.outcome_reason as execution_task_outcome_reason,
      ti.revision as execution_task_revision
    from public.requests r
    left join lateral (
      select a.*
      from public.request_attempts a
      where a.household_id = r.household_id
        and a.request_id = r.id
        and a.test_context_id is null
      order by a.legacy_backfill asc, a.created_at desc, a.id desc
      limit 1
    ) latest on true
    left join lateral (
      select a.id, a.accepted_at, a.terms_revision, a.terms
      from public.request_attempts a
      where a.household_id = r.household_id
        and a.request_id = r.id
        and a.test_context_id is null
        and a.attempt_kind in ('initial', 'reproposal')
        and a.state = 'accepted'
      order by a.accepted_at desc nulls last, a.created_at desc
      limit 1
    ) agreement on true
    left join public.task_instances ti
      on ti.household_id = r.household_id
     and ti.id = r.linked_task_instance_id
     and ti.test_context_id is null
    where r.household_id = v_household_id
      and r.test_context_id is null
  ), shaped as (
    select
      rr.*,
      jsonb_build_object(
        'request_id', rr.id,
        'request_kind', rr.request_kind,
        'title', rr.shared_title,
        'message', rr.shared_message,
        'due_at', rr.due_at,
        'legacy_status', rr.status,
        'request_revision', rr.revision,
        'agreement_established', rr.agreement_attempt_id is not null,
        'agreement', case when rr.agreement_attempt_id is null then null else jsonb_build_object(
          'attempt_id', rr.agreement_attempt_id,
          'accepted_at', rr.agreement_accepted_at,
          'terms_revision', rr.agreement_terms_revision,
          'terms', rr.agreement_terms
        ) end,
        'current_attempt', case when rr.latest_attempt_id is null then null else jsonb_build_object(
          'attempt_id', rr.latest_attempt_id,
          'attempt_kind', rr.latest_attempt_kind,
          'state', rr.latest_attempt_state,
          'terms_revision', rr.latest_terms_revision,
          'terms', rr.latest_terms,
          'reply_due_at', rr.latest_reply_due_at,
          'revision', rr.latest_attempt_revision
        ) end,
        'coordination_state', case
          when rr.agreement_attempt_id is not null
               and rr.latest_attempt_kind in ('change', 'cancel')
               and rr.latest_attempt_state in ('pending', 'checking', 'consulting', 'awaiting_confirmation')
            then 'agreement_with_negotiation'
          when rr.agreement_attempt_id is not null then 'agreed'
          when rr.latest_attempt_state is not null then rr.latest_attempt_state
          else rr.status
        end,
        'execution', case when rr.linked_task_instance_id is null then null else jsonb_build_object(
          'task_id', rr.linked_task_instance_id,
          'status', rr.execution_task_status,
          'scheduled_date', rr.execution_task_scheduled_date,
          'due_at', rr.execution_task_due_at,
          'completed_at', rr.execution_task_completed_at,
          'outcome_reason', rr.execution_task_outcome_reason,
          'revision', rr.execution_task_revision
        ) end,
        'action_target', jsonb_build_object(
          'kind', 'request',
          'request_id', rr.id,
          'attempt_id', rr.latest_attempt_id,
          'attempt_revision', rr.latest_attempt_revision,
          'terms_revision', rr.latest_terms_revision
        )
      ) as item
    from request_rows rr
  )
  select
    coalesce(
      jsonb_agg(item order by coalesce(latest_reply_due_at, due_at) nulls last, created_at desc)
        filter (where (
          (v_actor_ref_id is not null and recipient_actor_ref_id = v_actor_ref_id)
          or (recipient_actor_ref_id is null and recipient_id = p_actor_id)
        )),
      '[]'::jsonb
    ),
    coalesce(
      jsonb_agg(item order by created_at desc)
        filter (where (
          (v_actor_ref_id is not null and requester_actor_ref_id = v_actor_ref_id)
          or (requester_actor_ref_id is null and requester_id = p_actor_id)
        )),
      '[]'::jsonb
    )
  into v_incoming, v_outgoing
  from shaped;

  return jsonb_build_object(
    'generated_at', now(),
    'household_id', v_household_id,
    'incoming', v_incoming,
    'outgoing', v_outgoing
  );
end;
$$;

revoke all on function public.server_read_request_workspace(uuid)
  from public, anon, authenticated;
grant execute on function public.server_read_request_workspace(uuid) to service_role;

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

-- F2 real two-account remediation:
-- accepting a one-off pickup/dropoff assignment must re-resolve same-day
-- role-derived routine tasks. Explicit agreements/overrides remain protected.

create or replace function private.fn_reconcile_transport_role_dependents_v1(
  p_household_id uuid,
  p_request_id uuid,
  p_attempt_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_source text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_request public.requests%rowtype;
  v_attempt public.request_attempts%rowtype;
  v_anchor record;
  v_dep public.task_instances%rowtype;
  v_strategy text;
  v_desired_user uuid;
  v_desired_actor_ref uuid;
  v_other_user uuid;
  v_other_count int;
  v_previous_user uuid;
  v_previous_actor_ref uuid;
  v_previous_revision bigint;
  v_new_revision bigint;
  v_updated int := 0;
  v_unresolved int := 0;
  v_updates jsonb := '[]'::jsonb;
begin
  select * into v_request
  from public.requests
  where household_id=p_household_id and id=p_request_id;

  if not found
     or v_request.request_kind is distinct from 'assignment_change'
     or v_request.test_context_id is not null then
    return jsonb_build_object('updated',0,'unresolved',0,'items','[]'::jsonb);
  end if;

  select * into v_attempt
  from public.request_attempts
  where household_id=p_household_id
    and id=p_attempt_id
    and request_id=p_request_id;

  if not found or v_attempt.state is distinct from 'accepted' then
    return jsonb_build_object('updated',0,'unresolved',0,'items','[]'::jsonb);
  end if;

  -- The canonical request terms are the exact tasks that were agreed.
  -- Re-read those tasks after the assignment/material-patch transaction so
  -- dependent resolution follows the final accepted occurrence state.
  for v_anchor in
    select
      ti.id,
      ti.scheduled_date,
      ti.planned_assignee_id,
      ti.planned_assignee_actor_ref_id,
      td.code
    from jsonb_array_elements(coalesce(v_attempt.terms->'assignment_targets','[]'::jsonb)) target
    join public.task_instances ti
      on ti.household_id=p_household_id
     and ti.id=(target->>'task_id')::uuid
    join public.task_definitions td
      on td.household_id=ti.household_id
     and td.id=ti.task_definition_id
    where td.code in ('pickup','dropoff')
      and ti.status in ('todo','in_progress')
    order by ti.scheduled_date,ti.id
  loop
    if v_anchor.planned_assignee_id is null then
      v_unresolved := v_unresolved + 1;
      continue;
    end if;

    for v_dep in
      select ti.*
      from public.task_instances ti
      join public.recurrence_rules rr
        on rr.household_id=ti.household_id
       and rr.id=ti.recurrence_rule_id
      where ti.household_id=p_household_id
        and ti.scheduled_date=v_anchor.scheduled_date
        and ti.status in ('todo','in_progress')
        and coalesce(ti.assignment_source,'legacy_snapshot')='legacy_snapshot'
        and ti.active_claimant_actor_ref_id is null
        and not (coalesce(ti.source_context,'{}'::jsonb) ? 'transport_occurrence_override')
        and (
          (v_anchor.code='pickup' and rr.assignee_strategy in ('pickup_assignee','nonpickup_adult'))
          or
          (v_anchor.code='dropoff' and rr.assignee_strategy='dropoff_assignee')
        )
        and not exists(
          select 1
          from public.task_events e
          where e.household_id=ti.household_id
            and e.task_instance_id=ti.id
            and e.event_type in ('assignment_agreed','reassigned_once','cancelled')
        )
      order by ti.due_at nulls last,ti.id
      for update of ti
    loop
      select rr.assignee_strategy into v_strategy
      from public.recurrence_rules rr
      where rr.household_id=p_household_id and rr.id=v_dep.recurrence_rule_id;

      v_desired_user := null;
      v_other_user := null;
      v_other_count := 0;

      if v_strategy in ('pickup_assignee','dropoff_assignee') then
        v_desired_user := v_anchor.planned_assignee_id;
      elsif v_strategy='nonpickup_adult' then
        select count(*), min(hm.user_id::text)::uuid
          into v_other_count,v_other_user
        from public.household_members hm
        where hm.household_id=p_household_id
          and hm.member_role='adult'
          and hm.user_id<>v_anchor.planned_assignee_id;

        -- With more than one possible non-pickup adult, do not guess.
        if v_other_count<>1 then
          v_unresolved := v_unresolved + 1;
          continue;
        end if;
        v_desired_user := v_other_user;
      end if;

      if v_desired_user is null then
        v_unresolved := v_unresolved + 1;
        continue;
      end if;

      select dar.id into v_desired_actor_ref
      from public.domain_actor_refs dar
      where dar.household_id=p_household_id
        and dar.actor_kind='real_user'
        and dar.real_user_id=v_desired_user
      order by dar.id
      limit 1;

      if v_desired_actor_ref is null then
        v_unresolved := v_unresolved + 1;
        continue;
      end if;

      if v_dep.planned_assignee_id is not distinct from v_desired_user
         and v_dep.planned_assignee_actor_ref_id is not distinct from v_desired_actor_ref then
        continue;
      end if;

      v_previous_user := v_dep.planned_assignee_id;
      v_previous_actor_ref := v_dep.planned_assignee_actor_ref_id;
      v_previous_revision := v_dep.revision;

      update public.task_instances
      set planned_assignee_id=v_desired_user,
          planned_assignee_actor_ref_id=v_desired_actor_ref,
          assignment_mode='person',
          -- Keep this rule-derived: the explicit agreement is the transport
          -- occurrence, not every dependent routine task independently.
          assignment_source='legacy_snapshot',
          revision=revision+1
      where household_id=p_household_id and id=v_dep.id
      returning revision into v_new_revision;

      insert into public.task_events(
        household_id,
        task_instance_id,
        actor_id,
        actor_ref_id,
        test_context_id,
        event_type,
        payload,
        source,
        idempotency_key
      ) values(
        p_household_id,
        v_dep.id,
        p_operator_user_id,
        p_actor_ref_id,
        null,
        'edited',
        jsonb_build_object(
          'reason','transport_role_dependency',
          'request_id',p_request_id,
          'attempt_id',p_attempt_id,
          'anchor_task_id',v_anchor.id,
          'anchor_code',v_anchor.code,
          'assignee_strategy',v_strategy,
          'previous_assignee_user_id',v_previous_user,
          'previous_assignee_actor_ref_id',v_previous_actor_ref,
          'assignee_user_id',v_desired_user,
          'assignee_actor_ref_id',v_desired_actor_ref,
          'previous_revision',v_previous_revision,
          'revision',v_new_revision
        ),
        p_source,
        'request-role-dependency:'||p_attempt_id::text||':'||v_dep.id::text
      );

      v_updated := v_updated + 1;
      v_updates := v_updates || jsonb_build_array(jsonb_build_object(
        'task_id',v_dep.id,
        'strategy',v_strategy,
        'assignee_user_id',v_desired_user,
        'revision',v_new_revision
      ));
    end loop;
  end loop;

  return jsonb_build_object(
    'updated',v_updated,
    'unresolved',v_unresolved,
    'items',v_updates
  );
end;
$$;

revoke all on function private.fn_reconcile_transport_role_dependents_v1(uuid,uuid,uuid,uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function private.fn_reconcile_transport_role_dependents_v1(uuid,uuid,uuid,uuid,uuid,text)
  to service_role;

create or replace function public.server_tx_transition_request_v2(
  p_actor_id uuid,
  p_operation_id uuid,
  p_request_id uuid,
  p_attempt_id uuid,
  p_action text,
  p_terms jsonb,
  p_expected_revision bigint,
  p_expected_terms_revision integer,
  p_source text
) returns jsonb
language plpgsql
set search_path=''
as $$
declare
  c jsonb;
  v_result jsonb;
  v_patch_result jsonb;
  v_dependency_result jsonb;
begin
  c := private.fn_require_production_actor_context_v1(p_actor_id);

  v_result := private.fn_command_transition_request_attempt_v1(
    (c->>'household_id')::uuid,
    p_actor_id,
    (c->>'actor_ref_id')::uuid,
    null,
    p_request_id,
    p_attempt_id,
    p_action,
    p_terms,
    p_expected_revision,
    p_expected_terms_revision,
    p_operation_id,
    p_source
  );

  if v_result->>'state'='accepted' then
    v_patch_result := private.fn_apply_confirmed_initial_material_patch_v1(
      (c->>'household_id')::uuid,
      p_actor_id,
      (c->>'actor_ref_id')::uuid,
      p_request_id,
      p_attempt_id,
      p_source
    );

    if coalesce((v_patch_result->>'applied')::boolean,false) then
      v_result := v_result || jsonb_build_object('material_patch',v_patch_result);
    end if;

    -- Reconcile after any confirmed material patch so dependency resolution
    -- uses the final accepted task occurrence/date.
    v_dependency_result := private.fn_reconcile_transport_role_dependents_v1(
      (c->>'household_id')::uuid,
      p_request_id,
      p_attempt_id,
      p_actor_id,
      (c->>'actor_ref_id')::uuid,
      p_source
    );

    if coalesce((v_dependency_result->>'updated')::int,0)>0
       or coalesce((v_dependency_result->>'unresolved')::int,0)>0 then
      v_result := v_result || jsonb_build_object(
        'transport_role_dependents',
        v_dependency_result
      );
    end if;
  end if;

  return v_result;
end;
$$;

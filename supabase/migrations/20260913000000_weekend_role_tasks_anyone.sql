-- Weekend role-derived work is shared work when both adults are normally home.
-- Product decision 2026-09-13:
-- * live same-day transport assignment still wins, even on Saturday/Sunday;
-- * if the relevant transport role cannot resolve on Saturday/Sunday, the
--   role-derived task is `anyone`, not Papa/Mama fallback and not unassigned;
-- * explicit fallback remains available for unresolved weekday transport;
-- * this applies to all role-derived weekend work, including Shino medication
--   and medication/bowel-record routines.
-- * anyone tasks use an explicit claim/release/takeover lifecycle.

create or replace function private.fn_resolve_transport_role_assignment_v2(
  p_household_id uuid,
  p_date date,
  p_strategy text,
  p_fallback_assignee_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $weekend_resolver$
declare
  v_transport_user uuid;
  v_other_user uuid;
  v_other_count int;
  v_code text;
  v_weekend boolean:=extract(isodow from p_date)::int in (6,7);
begin
  if p_strategy not in ('pickup_assignee','dropoff_assignee','nonpickup_adult') then
    return jsonb_build_object('mode','unassigned','user_id',null);
  end if;

  v_code:=case when p_strategy='dropoff_assignee' then 'dropoff' else 'pickup' end;

  select ti.planned_assignee_id
    into v_transport_user
  from public.task_instances ti
  join public.task_definitions td
    on td.household_id=ti.household_id and td.id=ti.task_definition_id
  where ti.household_id=p_household_id
    and ti.scheduled_date=p_date
    and td.code=v_code
    and ti.test_context_id is null
    and ti.status in ('todo','in_progress')
    and coalesce(ti.assignment_mode,'person')='person'
    and ti.planned_assignee_id is not null
  order by ti.updated_at desc,ti.id
  limit 1;

  if p_strategy in ('pickup_assignee','dropoff_assignee') then
    if v_transport_user is not null then
      return jsonb_build_object('mode','person','user_id',v_transport_user);
    end if;
    if v_weekend then
      return jsonb_build_object('mode','anyone','user_id',null);
    end if;
    if p_fallback_assignee_id is not null then
      return jsonb_build_object('mode','person','user_id',p_fallback_assignee_id);
    end if;
    return jsonb_build_object('mode','unassigned','user_id',null);
  end if;

  if v_transport_user is not null then
    select count(*),min(hm.user_id::text)::uuid
      into v_other_count,v_other_user
    from public.household_members hm
    where hm.household_id=p_household_id
      and hm.member_role='adult'
      and hm.user_id<>v_transport_user;

    if v_other_count=1 then
      return jsonb_build_object('mode','person','user_id',v_other_user);
    end if;
  end if;

  if v_weekend then
    return jsonb_build_object('mode','anyone','user_id',null);
  end if;
  if p_fallback_assignee_id is not null then
    return jsonb_build_object('mode','person','user_id',p_fallback_assignee_id);
  end if;
  return jsonb_build_object('mode','unassigned','user_id',null);
end;
$weekend_resolver$;

revoke all on function private.fn_resolve_transport_role_assignment_v2(uuid,date,text,uuid)
  from public,anon,authenticated;
grant execute on function private.fn_resolve_transport_role_assignment_v2(uuid,date,text,uuid)
  to service_role;

create or replace function private.materialize_recurrence_rule(
  p_household_id uuid,
  p_rule_id uuid,
  p_from_date date,
  p_to_date date
)
returns void
language plpgsql
set search_path=''
as $weekend_materialize$
declare
  v_rule public.recurrence_rules%rowtype;
  v_task public.task_definitions%rowtype;
  v_date date;
  v_logical_key text;
  v_assignment jsonb;
  v_assignment_mode text;
  v_planned_assignee uuid;
  v_planned_actor_ref uuid;
  v_due_at timestamptz;
  v_instance_id uuid;
  v_subtask record;
begin
  select * into v_rule
  from public.recurrence_rules
  where id=p_rule_id and household_id=p_household_id;
  if not found or not v_rule.active then return; end if;

  select * into v_task
  from public.task_definitions
  where id=v_rule.task_definition_id and household_id=p_household_id;
  if not found or not v_task.is_active then return; end if;

  v_date:=p_from_date;
  while v_date<=p_to_date loop
    if extract(isodow from v_date)::smallint=v_rule.weekday
       and v_date>=v_rule.effective_from
       and (v_rule.effective_to is null or v_date<=v_rule.effective_to) then
      v_logical_key:='rec:'||v_rule.task_definition_id::text||':'||v_date::text||':'||v_rule.slot_key;

      if not exists(
        select 1 from public.task_instances
        where household_id=p_household_id and logical_occurrence_key=v_logical_key
      ) then
        v_planned_assignee:=null;
        v_planned_actor_ref:=null;
        v_assignment_mode:='unassigned';

        if v_rule.assignee_strategy='fixed' then
          v_planned_assignee:=v_rule.planned_assignee_id;
          v_assignment_mode:=case when v_planned_assignee is null then 'unassigned' else 'person' end;
        elsif v_rule.assignee_strategy in ('dropoff_assignee','pickup_assignee','nonpickup_adult') then
          v_assignment:=private.fn_resolve_transport_role_assignment_v2(
            p_household_id,v_date,v_rule.assignee_strategy,v_rule.fallback_assignee_id
          );
          v_assignment_mode:=coalesce(v_assignment->>'mode','unassigned');
          v_planned_assignee:=nullif(v_assignment->>'user_id','')::uuid;
        end if;

        if v_assignment_mode='person' and v_planned_assignee is not null then
          select dar.id into v_planned_actor_ref
          from public.domain_actor_refs dar
          where dar.household_id=p_household_id
            and dar.actor_kind='real_user'
            and dar.real_user_id=v_planned_assignee
            and dar.test_context_id is null
          order by dar.id
          limit 1;
          if v_planned_actor_ref is null then
            v_assignment_mode:='unassigned';
            v_planned_assignee:=null;
          end if;
        end if;

        v_due_at:=case
          when v_rule.scheduled_local_time is null then null
          else ((v_date::text||' '||v_rule.scheduled_local_time::text)::timestamp at time zone 'Asia/Tokyo')
        end;

        insert into public.task_instances(
          household_id,task_definition_id,recurrence_rule_id,logical_occurrence_key,
          origin,title,category,routine_phase,scheduled_date,due_at,
          planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,
          completion_mode,status,source,created_by
        ) values(
          p_household_id,v_rule.task_definition_id,v_rule.id,v_logical_key,
          'recurring',v_task.title,v_task.category,v_task.routine_phase,v_date,v_due_at,
          v_planned_assignee,v_planned_actor_ref,v_assignment_mode,
          v_task.completion_mode,'todo','recurring',v_rule.created_by
        )
        returning id into v_instance_id;

        if v_task.completion_mode='subtasks' then
          for v_subtask in
            select *
            from public.task_subtask_definitions
            where household_id=p_household_id
              and task_definition_id=v_task.id
              and is_active
            order by sort_order,id
          loop
            insert into public.task_subtask_instances(
              household_id,task_instance_id,source_definition_id,title,required,sort_order
            ) values(
              p_household_id,v_instance_id,v_subtask.id,v_subtask.title,
              v_subtask.required,v_subtask.sort_order
            );
          end loop;
        end if;
      end if;
    end if;
    v_date:=v_date+1;
  end loop;
end;
$weekend_materialize$;

create or replace function private.fn_reconcile_transport_role_date_v1(
  p_household_id uuid,
  p_date date,
  p_leg text,
  p_source text,
  p_anchor_task_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $weekend_reconcile$
declare
  v_dep record;
  v_assignment jsonb;
  v_desired_user uuid;
  v_desired_actor_ref uuid;
  v_desired_mode text;
  v_audit_actor_ref uuid;
  v_previous_user uuid;
  v_previous_actor_ref uuid;
  v_previous_mode text;
  v_previous_revision bigint;
  v_new_revision bigint;
  v_updated int:=0;
  v_items jsonb:='[]'::jsonb;
begin
  if p_leg not in ('pickup','dropoff') then
    raise exception 'INVALID_INPUT';
  end if;

  v_audit_actor_ref:=private.fn_household_system_actor_ref_v1(p_household_id);

  for v_dep in
    select ti.*,rr.assignee_strategy,rr.fallback_assignee_id
    from public.task_instances ti
    join public.recurrence_rules rr
      on rr.household_id=ti.household_id and rr.id=ti.recurrence_rule_id
    where ti.household_id=p_household_id
      and ti.scheduled_date=p_date
      and ti.test_context_id is null
      and ti.status in ('todo','in_progress')
      and coalesce(ti.assignment_source,'legacy_snapshot')='legacy_snapshot'
      and ti.active_claimant_actor_ref_id is null
      and not (coalesce(ti.source_context,'{}'::jsonb) ? 'transport_occurrence_override')
      and (
        (p_leg='pickup' and rr.assignee_strategy in ('pickup_assignee','nonpickup_adult'))
        or
        (p_leg='dropoff' and rr.assignee_strategy='dropoff_assignee')
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
    v_assignment:=private.fn_resolve_transport_role_assignment_v2(
      p_household_id,p_date,v_dep.assignee_strategy,v_dep.fallback_assignee_id
    );
    v_desired_mode:=coalesce(v_assignment->>'mode','unassigned');
    v_desired_user:=nullif(v_assignment->>'user_id','')::uuid;
    v_desired_actor_ref:=null;

    if v_desired_mode='person' and v_desired_user is not null then
      select dar.id
        into v_desired_actor_ref
      from public.domain_actor_refs dar
      where dar.household_id=p_household_id
        and dar.actor_kind='real_user'
        and dar.real_user_id=v_desired_user
        and dar.test_context_id is null
      order by dar.id
      limit 1;

      if v_desired_actor_ref is null then
        v_desired_user:=null;
        v_desired_mode:='unassigned';
      end if;
    else
      v_desired_user:=null;
    end if;

    if v_dep.planned_assignee_id is not distinct from v_desired_user
       and v_dep.planned_assignee_actor_ref_id is not distinct from v_desired_actor_ref
       and coalesce(v_dep.assignment_mode,v_desired_mode)=v_desired_mode then
      continue;
    end if;

    v_previous_user:=v_dep.planned_assignee_id;
    v_previous_actor_ref:=v_dep.planned_assignee_actor_ref_id;
    v_previous_mode:=coalesce(v_dep.assignment_mode,
      case when v_dep.planned_assignee_id is null then 'unassigned' else 'person' end);
    v_previous_revision:=v_dep.revision;

    update public.task_instances
    set planned_assignee_id=v_desired_user,
        planned_assignee_actor_ref_id=v_desired_actor_ref,
        assignment_mode=v_desired_mode,
        assignment_source='legacy_snapshot',
        active_claimant_actor_ref_id=null,
        claimed_at=null,
        revision=revision+1
    where household_id=p_household_id and id=v_dep.id
    returning revision into v_new_revision;

    insert into public.task_events(
      household_id,task_instance_id,actor_id,actor_ref_id,test_context_id,
      event_type,payload,source,idempotency_key
    ) values(
      p_household_id,v_dep.id,null,v_audit_actor_ref,null,
      'edited',
      jsonb_build_object(
        'reason','transport_role_weekend_anyone_reconcile',
        'anchor_task_id',p_anchor_task_id,
        'transport_leg',p_leg,
        'assignee_strategy',v_dep.assignee_strategy,
        'fallback_assignee_user_id',v_dep.fallback_assignee_id,
        'previous_assignment_mode',v_previous_mode,
        'previous_assignee_user_id',v_previous_user,
        'previous_assignee_actor_ref_id',v_previous_actor_ref,
        'assignment_mode',v_desired_mode,
        'assignee_user_id',v_desired_user,
        'assignee_actor_ref_id',v_desired_actor_ref,
        'previous_revision',v_previous_revision,
        'revision',v_new_revision
      ),
      coalesce(nullif(p_source,''),'transport_role_reconcile'),
      'transport-role-weekend:'||coalesce(p_anchor_task_id::text,'none')||':'||v_dep.id::text||':'||v_new_revision::text
    );

    v_updated:=v_updated+1;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'task_id',v_dep.id,
      'strategy',v_dep.assignee_strategy,
      'assignment_mode',v_desired_mode,
      'assignee_user_id',v_desired_user,
      'revision',v_new_revision
    ));
  end loop;

  return jsonb_build_object('updated',v_updated,'items',v_items);
end;
$weekend_reconcile$;

revoke all on function private.fn_reconcile_transport_role_date_v1(uuid,date,text,text,uuid)
  from public,anon,authenticated;
grant execute on function private.fn_reconcile_transport_role_date_v1(uuid,date,text,text,uuid)
  to service_role;

-- Generic Task anyone claim lifecycle (Q107-Q109), parallel to Shopping.
create or replace function public.server_tx_task_anyone_claim_v1(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_action text,
  p_expected_revision bigint,
  p_source text default 'pwa'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $task_anyone_claim$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_claim jsonb;
  v_receipt_id uuid;
  v_task public.task_instances%rowtype;
  v_new_revision bigint;
  v_event_type text;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null
     or p_expected_revision is null
     or p_action not in ('claim','release','takeover')
     or p_source not in ('pwa','line') then
    raise exception 'INVALID_INPUT';
  end if;

  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  v_actor_ref_id:=(v_context->>'actor_ref_id')::uuid;

  v_claim:=private.fn_claim_canonical_operation_v1(
    v_household_id,p_actor_id,v_actor_ref_id,null,p_operation_id,
    'task.anyone_claim',
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'task_id',p_task_id,'action',p_action,
      'expected_revision',p_expected_revision,'source',p_source
    ))
  );
  if v_claim->>'disposition'='replay' then
    return v_claim->'result_payload';
  end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;

  select * into v_task
  from public.task_instances
  where household_id=v_household_id and id=p_task_id and test_context_id is null
  for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if v_task.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_task.status not in ('todo','in_progress') then raise exception 'TASK_NOT_OPEN'; end if;
  if coalesce(v_task.assignment_mode,
      case when v_task.planned_assignee_id is null then 'unassigned' else 'person' end)<>'anyone'
     or v_task.planned_assignee_id is not null
     or v_task.planned_assignee_actor_ref_id is not null then
    raise exception 'TASK_NOT_ANYONE';
  end if;

  if p_action='claim' then
    if v_task.active_claimant_actor_ref_id is not null then
      raise exception 'TASK_ALREADY_CLAIMED';
    end if;
    update public.task_instances
    set active_claimant_actor_ref_id=v_actor_ref_id,claimed_at=now(),revision=revision+1
    where id=p_task_id and household_id=v_household_id
    returning revision into v_new_revision;
    v_event_type:='assignment_claimed';
  elsif p_action='release' then
    if v_task.active_claimant_actor_ref_id is distinct from v_actor_ref_id then
      raise exception 'TASK_CLAIM_NOT_OWNED';
    end if;
    update public.task_instances
    set active_claimant_actor_ref_id=null,claimed_at=null,revision=revision+1
    where id=p_task_id and household_id=v_household_id
    returning revision into v_new_revision;
    v_event_type:='assignment_released';
  else
    if v_task.active_claimant_actor_ref_id is null
       or v_task.active_claimant_actor_ref_id=v_actor_ref_id then
      raise exception 'TASK_TAKEOVER_NOT_REQUIRED';
    end if;
    update public.task_instances
    set active_claimant_actor_ref_id=v_actor_ref_id,claimed_at=now(),revision=revision+1
    where id=p_task_id and household_id=v_household_id
    returning revision into v_new_revision;
    v_event_type:='assignment_takeover';
  end if;

  insert into public.task_events(
    household_id,task_instance_id,actor_id,actor_ref_id,test_context_id,
    event_type,payload,source,idempotency_key
  ) values(
    v_household_id,p_task_id,p_actor_id,v_actor_ref_id,null,
    v_event_type,
    jsonb_build_object(
      'assignment_mode','anyone',
      'action',p_action,
      'previous_claimant_actor_ref_id',v_task.active_claimant_actor_ref_id,
      'active_claimant_actor_ref_id',
        case when p_action='release' then null else v_actor_ref_id end,
      'previous_revision',v_task.revision,
      'revision',v_new_revision
    ),
    p_source,
    'canonical:'||p_operation_id::text
  );

  v_result:=jsonb_build_object(
    'task_id',p_task_id,
    'assignment_mode','anyone',
    'claim_action',p_action,
    'active_claimant_actor_ref_id',
      case when p_action='release' then null else v_actor_ref_id end,
    'revision',v_new_revision
  );
  perform private.fn_complete_canonical_operation_v1(
    v_receipt_id,'task',p_task_id,v_result
  );
  return v_result;
end;
$task_anyone_claim$;

revoke all on function public.server_tx_task_anyone_claim_v1(uuid,uuid,uuid,text,bigint,text)
  from public,anon,authenticated;
grant execute on function public.server_tx_task_anyone_claim_v1(uuid,uuid,uuid,text,bigint,text)
  to service_role;

-- Final DailyBrief projection: unclaimed anyone tasks are shared work visible to
-- both adults, not assignment_needed. Claimed anyone work appears only to the
-- claimant through the existing base-reader claimant predicate.
create or replace function public.server_read_daily_brief(
  p_actor_id uuid,
  p_local_date date default null
) returns jsonb
language plpgsql
stable
set search_path=''
as $weekend_brief$
declare
  v_household_id uuid;
  v_date date:=coalesce(p_local_date,(now() at time zone 'Asia/Tokyo')::date);
  v_brief jsonb;
  v_anyone jsonb:='[]'::jsonb;
  v_urgent jsonb:='[]'::jsonb;
  v_groups jsonb;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;
  select hm.household_id into v_household_id
  from public.household_members hm
  where hm.user_id=p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  v_brief:=public.server_read_daily_brief_pre_assignment_action_v1(
    p_actor_id,p_local_date
  );

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',t.id,
    'title',t.title||'（誰でもOK）',
    'status',t.status,
    'task_kind',t.task_kind,
    'category',t.category,
    'routine_phase',t.routine_phase,
    'scheduled_date',t.scheduled_date,
    'due_at',t.due_at,
    'planned_assignee_id',null,
    'planned_assignee_actor_ref_id',null,
    'assignment_mode','anyone',
    'completion_mode',t.completion_mode,
    'expectation',coalesce(t.expectation,'normal'),
    'duplicate_sensitivity',coalesce(t.duplicate_sensitivity,'normal'),
    'revision',t.revision,
    'action_target',jsonb_build_object('kind','task','task_id',t.id,'revision',t.revision)
  ) order by t.due_at nulls last,t.title),'[]'::jsonb)
  into v_anyone
  from public.task_instances t
  where t.household_id=v_household_id
    and t.test_context_id is null
    and t.scheduled_date=v_date
    and t.status in ('todo','in_progress')
    and t.attention_state='active'
    and t.assignment_mode='anyone'
    and t.active_claimant_actor_ref_id is null;

  if jsonb_array_length(v_anyone)>0 then
    v_brief:=v_brief||jsonb_build_object(
      'tasks',coalesce(v_brief->'tasks','[]'::jsonb)||v_anyone
    );

    select jsonb_build_object(
      'morning',coalesce(v_brief#>'{own_task_groups,morning}','[]'::jsonb)
        ||coalesce(jsonb_agg(item order by item->>'due_at',item->>'title')
          filter(where item->>'routine_phase'='morning'),'[]'::jsonb),
      'daytime',coalesce(v_brief#>'{own_task_groups,daytime}','[]'::jsonb)
        ||coalesce(jsonb_agg(item order by item->>'due_at',item->>'title')
          filter(where coalesce(item->>'routine_phase','') not in ('morning','evening')
            and coalesce(item->>'expectation','normal')<>'optional'),'[]'::jsonb),
      'evening',coalesce(v_brief#>'{own_task_groups,evening}','[]'::jsonb)
        ||coalesce(jsonb_agg(item order by item->>'due_at',item->>'title')
          filter(where item->>'routine_phase'='evening'
            and coalesce(item->>'expectation','normal')<>'optional'),'[]'::jsonb),
      'optional',coalesce(v_brief#>'{own_task_groups,optional}','[]'::jsonb)
        ||coalesce(jsonb_agg(item order by item->>'due_at',item->>'title')
          filter(where coalesce(item->>'expectation','normal')='optional'),'[]'::jsonb)
    )
    into v_groups
    from jsonb_array_elements(v_anyone) item;

    v_brief:=v_brief||jsonb_build_object(
      'own_task_groups',v_groups,
      'sections',coalesce(v_brief->'sections','{}'::jsonb)
        ||jsonb_build_object('own_task_groups',v_groups)
    );
  end if;

  -- anyone is already a valid assignment mode: never present it as
  -- "担当未定 / 先に決めること".
  select coalesce(jsonb_agg(item order by ord),'[]'::jsonb)
  into v_urgent
  from jsonb_array_elements(coalesce(v_brief->'urgent_actions','[]'::jsonb))
    with ordinality as entries(item,ord)
  left join public.task_instances t
    on item->>'kind'='assignment_needed'
   and nullif(item->>'task_id','') is not null
   and t.household_id=v_household_id
   and t.id=(item->>'task_id')::uuid
  where not (
    item->>'kind'='assignment_needed'
    and coalesce(t.assignment_mode,'unassigned')='anyone'
  );

  -- Preserve assignment-request negotiation enrichment from the prior wrapper.
  select coalesce(jsonb_agg(
    case when pending.request_id is not null then
      item
      ||jsonb_build_object(
        'kind','assignment_negotiation',
        'title',coalesce(nullif(item->>'title',''),'担当未定')
          ||' → '||pending.recipient_label||'にお願い中',
        'state',pending.state,
        'request_id',pending.request_id,
        'attempt_id',pending.attempt_id,
        'reply_due_at',pending.reply_due_at
      )
    else item end
    order by ord
  ),'[]'::jsonb)
  into v_urgent
  from jsonb_array_elements(v_urgent) with ordinality as entries(item,ord)
  left join lateral (
    select r.id as request_id,a.id as attempt_id,a.state,a.reply_due_at,
      case hm.family_role when 'mama' then 'ママ' when 'papa' then 'パパ' else '相手' end as recipient_label
    from public.requests r
    join lateral (
      select x.id,x.state,x.reply_due_at
      from public.request_attempts x
      where x.household_id=r.household_id
        and x.request_id=r.id
        and x.test_context_id is null
        and x.state in ('pending','checking','consulting','awaiting_confirmation')
      order by x.created_at desc,x.id desc
      limit 1
    ) a on true
    left join public.household_members hm
      on hm.household_id=r.household_id and hm.user_id=r.recipient_id
    where item->>'kind'='assignment_needed'
      and nullif(item->>'task_id','') is not null
      and r.household_id=v_household_id
      and r.test_context_id is null
      and r.request_kind='assignment_change'
      and r.assignment_task_instance_id=(item->>'task_id')::uuid
    order by r.created_at desc,r.id desc
    limit 1
  ) pending on true;

  return v_brief||jsonb_build_object(
    'urgent_actions',v_urgent,
    'sections',coalesce(v_brief->'sections','{}'::jsonb)
      ||jsonb_build_object('confirm_first',v_urgent)
  );
end;
$weekend_brief$;

revoke all on function public.server_read_daily_brief(uuid,date)
  from public,anon,authenticated;
grant execute on function public.server_read_daily_brief(uuid,date)
  to service_role;

-- Converge existing open production role-derived tasks to the new rule.
-- On weekends without live transport this changes stale Papa/unassigned rows
-- to `anyone`; protected/claimed/agreement/override rows are excluded by the
-- reconciliation function.
do $weekend_backfill$
declare
  x record;
begin
  for x in
    select distinct ti.household_id,ti.scheduled_date
    from public.task_instances ti
    join public.recurrence_rules rr
      on rr.household_id=ti.household_id and rr.id=ti.recurrence_rule_id
    where ti.status in ('todo','in_progress')
      and ti.test_context_id is null
      and rr.assignee_strategy in ('pickup_assignee','dropoff_assignee','nonpickup_adult')
  loop
    perform private.fn_reconcile_transport_role_date_v1(
      x.household_id,x.scheduled_date,'pickup','migration_weekend_anyone',null
    );
    perform private.fn_reconcile_transport_role_date_v1(
      x.household_id,x.scheduled_date,'dropoff','migration_weekend_anyone',null
    );
  end loop;
end;
$weekend_backfill$;

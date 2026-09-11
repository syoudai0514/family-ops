-- F2 real-use UX remediation: `担当未定` in LINE Today must be actionable.
--
-- Direct choices:
--   * self       -> assign the open task to the current actor immediately
--   * anyone     -> change the open task to `誰でもOK` immediately
-- Partner choice:
--   * never assigns the partner silently; it creates an assignment Request
--     against the exact unassigned Task revision. The Task remains unassigned
--     until the recipient accepts through the existing canonical RequestAttempt
--     transition. While that Request is active, DailyBrief renders it as
--     `... -> ママ/パパにお願い中` rather than repeatedly nagging `担当未定`.

create or replace function public.server_tx_line_assign_unassigned_task_v1(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_choice text,
  p_expected_revision bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_claim jsonb;
  v_receipt_id uuid;
  v_task public.task_instances%rowtype;
  v_new_revision bigint;
  v_assignment_mode text;
  v_assignee_actor_ref_id uuid;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null
     or p_expected_revision is null or p_choice not in ('self','anyone') then
    raise exception 'INVALID_INPUT';
  end if;

  c := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (c->>'household_id')::uuid;
  v_actor_ref_id := (c->>'actor_ref_id')::uuid;

  v_claim := private.fn_claim_canonical_operation_v1(
    v_household_id,
    p_actor_id,
    v_actor_ref_id,
    null,
    p_operation_id,
    'task.assignment.resolve_unassigned',
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'task_id', p_task_id,
      'choice', p_choice,
      'expected_revision', p_expected_revision,
      'source', 'line'
    ))
  );
  if v_claim->>'disposition' = 'replay' then
    return v_claim->'result_payload';
  end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_task
  from public.task_instances
  where household_id = v_household_id
    and id = p_task_id
    and test_context_id is null
  for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if v_task.revision is distinct from p_expected_revision then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  if v_task.status not in ('todo','in_progress') then
    raise exception 'TASK_NOT_OPEN';
  end if;
  if coalesce(
       v_task.assignment_mode,
       case when v_task.planned_assignee_actor_ref_id is null
                  and v_task.planned_assignee_id is null
            then 'unassigned' else 'person' end
     ) <> 'unassigned'
     or v_task.planned_assignee_actor_ref_id is not null
     or v_task.planned_assignee_id is not null then
    raise exception 'TASK_ASSIGNMENT_ALREADY_DECIDED';
  end if;

  if p_choice = 'self' then
    v_assignment_mode := 'person';
    v_assignee_actor_ref_id := v_actor_ref_id;
  else
    v_assignment_mode := 'anyone';
    v_assignee_actor_ref_id := null;
  end if;

  update public.task_instances
  set assignment_mode = v_assignment_mode,
      assignment_source = 'manual',
      planned_assignee_actor_ref_id = v_assignee_actor_ref_id,
      planned_assignee_id = case when p_choice = 'self' then p_actor_id else null end,
      active_claimant_actor_ref_id = null,
      claimed_at = null,
      revision = revision + 1
  where household_id = v_household_id and id = p_task_id
  returning revision into v_new_revision;

  insert into public.task_events(
    household_id, task_instance_id, actor_id, actor_ref_id, test_context_id,
    event_type, payload, source, idempotency_key
  ) values (
    v_household_id, p_task_id, p_actor_id, v_actor_ref_id, null,
    'assignment_changed',
    jsonb_build_object(
      'previous_assignment_mode', coalesce(v_task.assignment_mode, 'unassigned'),
      'previous_assignee_actor_ref_id', v_task.planned_assignee_actor_ref_id,
      'assignment_mode', v_assignment_mode,
      'assignee_actor_ref_id', v_assignee_actor_ref_id,
      'previous_revision', v_task.revision,
      'revision', v_new_revision,
      'resolution', 'line_unassigned_choice'
    ),
    'line',
    'canonical:' || p_operation_id::text
  );

  v_result := jsonb_build_object(
    'task_id', p_task_id,
    'title', v_task.title,
    'choice', p_choice,
    'assignment_mode', v_assignment_mode,
    'planned_assignee_actor_ref_id', v_assignee_actor_ref_id,
    'revision', v_new_revision
  );
  perform private.fn_complete_canonical_operation_v1(
    v_receipt_id, 'task', p_task_id, v_result
  );
  return v_result;
end;
$$;

revoke all on function public.server_tx_line_assign_unassigned_task_v1(
  uuid,uuid,uuid,text,bigint
) from public, anon, authenticated;
grant execute on function public.server_tx_line_assign_unassigned_task_v1(
  uuid,uuid,uuid,text,bigint
) to service_role;

create or replace function public.server_tx_line_request_unassigned_task_assignment_v1(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_expected_revision bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_partner_user_id uuid;
  v_partner_actor_ref_id uuid;
  v_partner_role text;
  v_claim jsonb;
  v_receipt_id uuid;
  v_task public.task_instances%rowtype;
  v_request_id uuid;
  v_attempt_id uuid;
  v_reply_due timestamptz;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null
     or p_expected_revision is null then
    raise exception 'INVALID_INPUT';
  end if;

  c := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (c->>'household_id')::uuid;
  v_actor_ref_id := (c->>'actor_ref_id')::uuid;

  v_claim := private.fn_claim_canonical_operation_v1(
    v_household_id,
    p_actor_id,
    v_actor_ref_id,
    null,
    p_operation_id,
    'request.create.unassigned_assignment',
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'task_id', p_task_id,
      'expected_revision', p_expected_revision,
      'source', 'line'
    ))
  );
  if v_claim->>'disposition' = 'replay' then
    return v_claim->'result_payload';
  end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_task
  from public.task_instances
  where household_id = v_household_id
    and id = p_task_id
    and test_context_id is null
  for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if v_task.revision is distinct from p_expected_revision then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  if v_task.status not in ('todo','in_progress') then
    raise exception 'TASK_NOT_OPEN';
  end if;
  if coalesce(
       v_task.assignment_mode,
       case when v_task.planned_assignee_actor_ref_id is null
                  and v_task.planned_assignee_id is null
            then 'unassigned' else 'person' end
     ) <> 'unassigned'
     or v_task.planned_assignee_actor_ref_id is not null
     or v_task.planned_assignee_id is not null then
    raise exception 'TASK_ASSIGNMENT_ALREADY_DECIDED';
  end if;

  if exists (
    select 1
    from public.requests r
    join public.request_attempts a
      on a.household_id = r.household_id and a.request_id = r.id
    where r.household_id = v_household_id
      and r.request_kind = 'assignment_change'
      and r.assignment_task_instance_id = p_task_id
      and r.test_context_id is null
      and a.test_context_id is null
      and a.state in ('pending','checking','consulting','awaiting_confirmation')
  ) then
    raise exception 'ASSIGNMENT_REQUEST_ALREADY_ACTIVE';
  end if;

  select hm.user_id, ar.id, hm.family_role
    into v_partner_user_id, v_partner_actor_ref_id, v_partner_role
  from public.household_members hm
  join public.domain_actor_refs ar
    on ar.household_id = hm.household_id
   and ar.actor_kind = 'real_user'
   and ar.real_user_id = hm.user_id
   and ar.test_context_id is null
  where hm.household_id = v_household_id
    and hm.user_id <> p_actor_id
  order by case hm.family_role when 'mama' then 1 when 'papa' then 2 else 3 end,
           hm.user_id
  limit 1;
  if v_partner_user_id is null or v_partner_actor_ref_id is null then
    raise exception 'PARTNER_NOT_AVAILABLE';
  end if;

  v_reply_due := private.fn_propose_request_reply_due_v1(v_task.due_at, now());

  insert into public.requests(
    household_id, requester_id, recipient_id,
    requester_actor_ref_id, recipient_actor_ref_id,
    request_kind, shared_title, shared_message, due_at, status,
    assignment_task_instance_id, assignment_scope
  ) values (
    v_household_id, p_actor_id, v_partner_user_id,
    v_actor_ref_id, v_partner_actor_ref_id,
    'assignment_change', v_task.title, '担当をお願いできますか？',
    v_task.due_at, 'pending', p_task_id, 'once'
  ) returning id into v_request_id;

  insert into public.request_attempts(
    household_id, request_id, attempt_kind, state,
    terms_revision, terms, reply_due_at, created_by_actor_ref_id
  ) values (
    v_household_id, v_request_id, 'initial', 'pending', 1,
    jsonb_build_object(
      'title', v_task.title,
      'due_at', v_task.due_at,
      'scope', 'once',
      'assignment_targets', jsonb_build_array(jsonb_build_object(
        'task_id', p_task_id,
        'revision', v_task.revision,
        'assignee_actor_ref_id', v_task.planned_assignee_actor_ref_id
      ))
    ),
    v_reply_due,
    v_actor_ref_id
  ) returning id into v_attempt_id;

  perform private.fn_emit_notification_intent_v1(
    v_household_id,
    p_actor_id,
    v_actor_ref_id,
    null,
    v_partner_actor_ref_id,
    'request.received',
    '担当のお願い',
    v_task.title,
    jsonb_build_object(
      'request_id', v_request_id,
      'attempt_id', v_attempt_id,
      'revision', 1,
      'terms_revision', 1,
      'request_kind', 'assignment_change',
      'scope', 'once',
      'reply_due_at', v_reply_due,
      'due_at', v_task.due_at,
      'task_id', p_task_id
    ),
    'request:received:' || v_request_id::text,
    'immediate',
    'normal',
    'request:' || v_request_id::text,
    v_reply_due,
    'request',
    v_request_id,
    1
  );

  v_result := jsonb_build_object(
    'request_id', v_request_id,
    'attempt_id', v_attempt_id,
    'state', 'pending',
    'terms_revision', 1,
    'reply_due_at', v_reply_due,
    'task_id', p_task_id,
    'title', v_task.title,
    'recipient_user_id', v_partner_user_id,
    'recipient_actor_ref_id', v_partner_actor_ref_id,
    'recipient_role', v_partner_role
  );
  perform private.fn_complete_canonical_operation_v1(
    v_receipt_id, 'request', v_request_id, v_result
  );
  return v_result;
end;
$$;

revoke all on function public.server_tx_line_request_unassigned_task_assignment_v1(
  uuid,uuid,uuid,bigint
) from public, anon, authenticated;
grant execute on function public.server_tx_line_request_unassigned_task_assignment_v1(
  uuid,uuid,uuid,bigint
) to service_role;

-- Wrap the current DailyBrief so an active assignment request replaces the
-- repeated `担当未定` nag for that exact Task. Keep the pre-existing F2
-- enrichment as the delegated source of truth.
alter function public.server_read_daily_brief(uuid,date)
  rename to server_read_daily_brief_pre_assignment_action_v1;

create or replace function public.server_read_daily_brief(
  p_actor_id uuid,
  p_local_date date default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_brief jsonb;
  v_urgent jsonb;
begin
  v_brief := public.server_read_daily_brief_pre_assignment_action_v1(
    p_actor_id, p_local_date
  );

  select coalesce(jsonb_agg(
    case when pending.request_id is not null then
      item
      || jsonb_build_object(
        'kind', 'assignment_negotiation',
        'title', coalesce(nullif(item->>'title',''), '担当未定')
          || ' → ' || pending.recipient_label || 'にお願い中',
        'state', pending.state,
        'request_id', pending.request_id,
        'attempt_id', pending.attempt_id,
        'reply_due_at', pending.reply_due_at
      )
    else item end
    order by ord
  ), '[]'::jsonb)
  into v_urgent
  from jsonb_array_elements(coalesce(v_brief->'urgent_actions','[]'::jsonb))
    with ordinality as entries(item, ord)
  left join lateral (
    select
      r.id as request_id,
      a.id as attempt_id,
      a.state,
      a.reply_due_at,
      case hm.family_role
        when 'mama' then 'ママ'
        when 'papa' then 'パパ'
        else '相手'
      end as recipient_label
    from public.requests r
    join lateral (
      select x.id, x.state, x.reply_due_at
      from public.request_attempts x
      where x.household_id = r.household_id
        and x.request_id = r.id
        and x.test_context_id is null
        and x.state in ('pending','checking','consulting','awaiting_confirmation')
      order by x.created_at desc, x.id desc
      limit 1
    ) a on true
    left join public.household_members hm
      on hm.household_id = r.household_id
     and hm.user_id = r.recipient_id
    where item->>'kind' = 'assignment_needed'
      and nullif(item->>'task_id','') is not null
      and r.household_id = (v_brief->>'household_id')::uuid
      and r.test_context_id is null
      and r.request_kind = 'assignment_change'
      and r.assignment_task_instance_id = (item->>'task_id')::uuid
    order by r.created_at desc, r.id desc
    limit 1
  ) pending on true;

  return v_brief || jsonb_build_object(
    'urgent_actions', v_urgent,
    'sections', coalesce(v_brief->'sections','{}'::jsonb)
      || jsonb_build_object('confirm_first', v_urgent)
  );
end;
$$;

revoke all on function public.server_read_daily_brief(uuid,date)
  from public, anon, authenticated;
grant execute on function public.server_read_daily_brief(uuid,date)
  to service_role;

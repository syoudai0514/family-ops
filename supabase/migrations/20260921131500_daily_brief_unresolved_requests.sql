-- Ensure every unresolved request/negotiation is visible in scheduled Daily Briefs.
-- Covers assigned-task handoff requests as well as unassigned-task negotiations.
CREATE OR REPLACE FUNCTION public.server_read_daily_brief_pre_codmon_readiness_v1(p_actor_id uuid, p_local_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_date date:=coalesce(p_local_date,(now() at time zone 'Asia/Tokyo')::date);
  v_brief jsonb;
  v_anyone jsonb:='[]'::jsonb;
  v_urgent jsonb:='[]'::jsonb;
  v_groups jsonb;
  v_request_waiting jsonb:='[]'::jsonb;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;
  select hm.household_id into v_household_id
  from public.household_members hm
  where hm.user_id=p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select id into v_actor_ref_id
  from public.domain_actor_refs
  where household_id=v_household_id
    and actor_kind='real_user'
    and real_user_id=p_actor_id
    and test_context_id is null;

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
    'active_claimant_actor_ref_id',t.active_claimant_actor_ref_id,
    'claimed_at',t.claimed_at,
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
    and (
      t.active_claimant_actor_ref_id is null
      or t.active_claimant_actor_ref_id is distinct from v_actor_ref_id
    );

  if jsonb_array_length(v_anyone)>0 then
    v_brief:=v_brief||jsonb_build_object(
      'tasks',coalesce(v_brief->'tasks','[]'::jsonb)||v_anyone
    );

    select jsonb_build_object(
      'morning',coalesce(v_brief#>'{own_task_groups,morning}','[]'::jsonb)
        ||coalesce(jsonb_agg(item order by item->>'due_at',item->>'title')
          filter(where item->>'routine_phase'='morning'
            and coalesce(item->>'expectation','normal')<>'optional'),'[]'::jsonb),
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

  -- Unresolved Requests must remain visible in every scheduled Daily Brief,
  -- even when the underlying task already has an assignee. The previous
  -- assignment-negotiation enrichment only covered assignment_needed rows,
  -- which missed the common "Papa担当 -> Mamaへ変更依頼" case.
  select coalesce(jsonb_agg(jsonb_build_object(
    'kind','request_followup',
    'request_id',r.id,
    'attempt_id',a.id,
    'state',a.state,
    'reply_due_at',a.reply_due_at,
    'title',
      case
        when r.requester_id=p_actor_id and a.state='pending'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：返事待ち'
        when r.requester_id=p_actor_id and a.state='checking'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：相手が引き受ける意向・最終確認待ち'
        when r.requester_id=p_actor_id and a.state='consulting'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：相談中'
        when r.requester_id=p_actor_id and a.state='awaiting_confirmation'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：条件の確認待ち'
        when r.recipient_id=p_actor_id and a.state='pending'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：返事が必要'
        when r.recipient_id=p_actor_id and a.state='checking'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：最終確認待ち（確定（引受））'
        when r.recipient_id=p_actor_id and a.state='consulting'
          then 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：相談中'
        else 'お願い「'||coalesce(nullif(r.shared_title,''),'お願い')||'」：条件の確認待ち'
      end
  ) order by coalesce(a.reply_due_at,r.due_at) nulls last,r.created_at),'[]'::jsonb)
  into v_request_waiting
  from public.requests r
  join lateral (
    select x.id,x.state,x.reply_due_at,x.created_at
    from public.request_attempts x
    where x.household_id=r.household_id
      and x.request_id=r.id
      and x.test_context_id is null
      and x.state in ('pending','checking','consulting','awaiting_confirmation')
    order by x.created_at desc,x.id desc
    limit 1
  ) a on true
  where r.household_id=v_household_id
    and r.test_context_id is null
    and (r.requester_id=p_actor_id or r.recipient_id=p_actor_id)
    and not exists (
      select 1
      from jsonb_array_elements(v_urgent) u
      where u->>'request_id'=r.id::text
    );

  return v_brief||jsonb_build_object(
    'urgent_actions',v_urgent,
    'waiting_checks',coalesce(v_brief->'waiting_checks','[]'::jsonb)||v_request_waiting,
    'sections',coalesce(v_brief->'sections','{}'::jsonb)
      ||jsonb_build_object(
        'confirm_first',v_urgent,
        'waiting_checks',coalesce(v_brief->'waiting_checks','[]'::jsonb)||v_request_waiting
      )
  );
end;
$function$


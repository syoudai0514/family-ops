-- Follow-up hardening for the F2 LINE assignment action read model.
-- Resolve household scope from the actor rather than depending on a
-- presentation field being present in the delegated DailyBrief JSON.

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
  v_household_id uuid;
  v_brief jsonb;
  v_urgent jsonb;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;
  select hm.household_id into v_household_id
  from public.household_members hm
  where hm.user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

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
      and r.household_id = v_household_id
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

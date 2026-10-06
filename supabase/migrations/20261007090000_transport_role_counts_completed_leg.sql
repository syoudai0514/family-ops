-- "その日に送る人 / 迎える人" must not disappear once the leg is done.
--
-- 2026-10-07: completing 「送り」 at 08:35 re-ran the role reconcile, which only looked
-- at an open (todo / in_progress) dropoff. With the dropoff completed it found no one
-- and unassigned the day's dropoff-assignee tasks (コドモン送信, 詩乃：コドモン入力（朝食）).
-- A completed leg still names who took (or picks up) the children; only a cancelled
-- one does not. Same function otherwise (20260913000000).

create or replace function private.fn_resolve_transport_role_assignment_v2(
  p_household_id uuid, p_date date, p_strategy text, p_fallback_assignee_id uuid
)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $function$
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

  -- An open leg first (it reflects the latest reassignment), else the completed one.
  select ti.planned_assignee_id
    into v_transport_user
  from public.task_instances ti
  join public.task_definitions td
    on td.household_id=ti.household_id and td.id=ti.task_definition_id
  where ti.household_id=p_household_id
    and ti.scheduled_date=p_date
    and td.code=v_code
    and ti.test_context_id is null
    and ti.status in ('todo','in_progress','completed')
    and coalesce(ti.assignment_mode,'person')='person'
    and ti.planned_assignee_id is not null
  order by (ti.status='completed'),ti.updated_at desc,ti.id
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
$function$;

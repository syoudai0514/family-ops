-- A LINE card authorizes exactly one reviewed transport occurrence and revision.
-- Keep this apart from generic task/request drafts: a transport change must
-- never turn into a second ToDo. Only the signed LINE worker can use these RPCs.
create table private.line_transport_assignment_previews (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  actor_id uuid not null,
  actor_ref_id uuid not null,
  operation_id uuid not null,
  task_id uuid not null,
  scheduled_date date not null,
  due_at timestamptz,
  title text not null,
  code text not null check (code in ('dropoff','pickup')),
  current_assignee_user_id uuid,
  current_assignee_actor_ref_id uuid,
  assignee_user_id uuid not null,
  assignee_actor_ref_id uuid not null,
  current_label text not null,
  target_label text not null,
  expected_revision bigint not null check (expected_revision >= 1),
  status text not null default 'draft'
    check (status in ('draft','superseded','cancelled','succeeded')),
  expires_at timestamptz not null default (clock_timestamp() + interval '15 minutes'),
  created_at timestamptz not null default clock_timestamp(),
  decided_at timestamptz,
  result jsonb,
  unique(actor_id,operation_id),
  foreign key(household_id,task_id) references public.task_instances(household_id,id),
  foreign key(household_id,actor_id) references public.household_members(household_id,user_id),
  foreign key(household_id,assignee_user_id) references public.household_members(household_id,user_id),
  foreign key(household_id,actor_ref_id) references public.domain_actor_refs(household_id,id),
  foreign key(household_id,assignee_actor_ref_id) references public.domain_actor_refs(household_id,id),
  foreign key(household_id,current_assignee_actor_ref_id) references public.domain_actor_refs(household_id,id)
);
create unique index line_transport_assignment_one_draft_idx
  on private.line_transport_assignment_previews(actor_id) where status='draft';
create index line_transport_assignment_latest_idx
  on private.line_transport_assignment_previews(actor_id,created_at desc,id desc);
alter table private.line_transport_assignment_previews enable row level security;
revoke all on private.line_transport_assignment_previews from public,anon,authenticated;
grant select,insert,update,delete on private.line_transport_assignment_previews to service_role;

-- JSON is assembled only from stored server-derived fields, including on replay.
create function private.fn_line_transport_assignment_preview_json_v1(
  p_preview private.line_transport_assignment_previews
) returns jsonb language sql stable security invoker set search_path='' as $$
  select jsonb_build_object(
    'id',p_preview.id,'status',p_preview.status,
    'household_id',p_preview.household_id,'actor_id',p_preview.actor_id,
    'task_id',p_preview.task_id,'scheduled_date',p_preview.scheduled_date,
    'due_at',p_preview.due_at,'title',p_preview.title,'code',p_preview.code,
    'current_assignee_user_id',p_preview.current_assignee_user_id,
    'assignee_user_id',p_preview.assignee_user_id,
    'current_label',p_preview.current_label,'target_label',p_preview.target_label,
    'expected_revision',p_preview.expected_revision,'expires_at',p_preview.expires_at,
    'result',p_preview.result
  );
$$;
revoke all on function private.fn_line_transport_assignment_preview_json_v1(private.line_transport_assignment_previews)
  from public,anon,authenticated;
grant execute on function private.fn_line_transport_assignment_preview_json_v1(private.line_transport_assignment_previews)
  to service_role;

create function public.server_tx_prepare_line_transport_assignment_v1(
  p_actor_id uuid,p_operation_id uuid,p_task_id uuid,
  p_assignee_user_id uuid,p_expected_revision bigint
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_target_ref_id uuid;
  v_current_ref_id uuid;
  v_target_label text;
  v_current_label text;
  v_task public.task_instances%rowtype;
  v_code text;
  v_preview private.line_transport_assignment_previews%rowtype;
begin
  if p_operation_id is null or p_task_id is null or p_assignee_user_id is null
    or p_expected_revision is null or p_expected_revision<1 then
    raise exception 'INVALID_INPUT';
  end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  v_actor_ref_id:=(v_context->>'actor_ref_id')::uuid;
  if not exists(select 1 from public.household_members m
    join public.domain_actor_refs ar on ar.household_id=m.household_id
      and ar.real_user_id=m.user_id and ar.actor_kind='real_user' and ar.test_context_id is null
    where m.household_id=v_household_id and m.user_id=p_actor_id
      and m.member_role='adult' and ar.id=v_actor_ref_id) then
    raise exception 'LINE_TRANSPORT_PREVIEW_ACTOR_INVALID';
  end if;
  -- Serialize a sender's cards so two preparations cannot both remain actionable.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'line-transport-assignment:'||p_actor_id::text,0));
  select * into v_preview from private.line_transport_assignment_previews
    where actor_id=p_actor_id and operation_id=p_operation_id;
  if found then
    if v_preview.household_id<>v_household_id or v_preview.actor_ref_id<>v_actor_ref_id
      or v_preview.task_id<>p_task_id or v_preview.assignee_user_id<>p_assignee_user_id
      or v_preview.expected_revision<>p_expected_revision then
      raise exception 'IDEMPOTENCY_CONFLICT';
    end if;
    return private.fn_line_transport_assignment_preview_json_v1(v_preview);
  end if;
  select ar.id,case m.family_role when 'papa' then 'パパ' when 'mama' then 'ママ'
      else coalesce(nullif(btrim(p.display_name),''),'家族') end
    into v_target_ref_id,v_target_label
  from public.household_members m
  join public.domain_actor_refs ar on ar.household_id=m.household_id
    and ar.real_user_id=m.user_id and ar.actor_kind='real_user' and ar.test_context_id is null
  left join public.profiles p on p.user_id=m.user_id
  where m.household_id=v_household_id and m.user_id=p_assignee_user_id and m.member_role='adult';
  if not found then raise exception 'LINE_TRANSPORT_PREVIEW_TARGET_INVALID'; end if;
  select ti.* into v_task from public.task_instances ti
    where ti.id=p_task_id and ti.household_id=v_household_id and ti.test_context_id is null
    for share;
  if not found then raise exception 'LINE_TRANSPORT_PREVIEW_TASK_NOT_FOUND'; end if;
  select td.code into v_code from public.task_definitions td
    where td.household_id=v_household_id and td.id=v_task.task_definition_id;
  if v_code is null or v_code not in ('dropoff','pickup')
    or v_task.task_kind is distinct from 'transport' or v_task.category is distinct from v_code then
    raise exception 'LINE_TRANSPORT_PREVIEW_TASK_INVALID';
  end if;
  if v_task.status not in ('todo','in_progress') then raise exception 'TASK_NOT_OPEN'; end if;
  if v_task.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_task.assignment_mode='person' then
    select ar.id,case m.family_role when 'papa' then 'パパ' when 'mama' then 'ママ'
        else coalesce(nullif(btrim(p.display_name),''),'家族') end
      into v_current_ref_id,v_current_label
    from public.household_members m
    join public.domain_actor_refs ar on ar.household_id=m.household_id
      and ar.real_user_id=m.user_id and ar.actor_kind='real_user' and ar.test_context_id is null
    left join public.profiles p on p.user_id=m.user_id
    where m.household_id=v_household_id and m.user_id=v_task.planned_assignee_id
      and m.member_role='adult' and ar.id=v_task.planned_assignee_actor_ref_id;
    if not found then raise exception 'LINE_TRANSPORT_PREVIEW_CURRENT_ASSIGNEE_INVALID'; end if;
  elsif v_task.assignment_mode in ('anyone','unassigned')
    and v_task.planned_assignee_id is null and v_task.planned_assignee_actor_ref_id is null then
    v_current_label:=case when v_task.assignment_mode='anyone' then '誰でもOK' else '未定' end;
  else
    raise exception 'LINE_TRANSPORT_PREVIEW_CURRENT_ASSIGNEE_INVALID';
  end if;
  if v_target_ref_id is not distinct from v_current_ref_id then
    raise exception 'LINE_TRANSPORT_PREVIEW_ALREADY_ASSIGNED';
  end if;
  update private.line_transport_assignment_previews
    set status='superseded',decided_at=clock_timestamp()
    where actor_id=p_actor_id and status='draft';
  insert into private.line_transport_assignment_previews(
    household_id,actor_id,actor_ref_id,operation_id,task_id,scheduled_date,due_at,title,code,
    current_assignee_user_id,current_assignee_actor_ref_id,assignee_user_id,assignee_actor_ref_id,
    current_label,target_label,expected_revision
  ) values(
    v_household_id,p_actor_id,v_actor_ref_id,p_operation_id,p_task_id,v_task.scheduled_date,v_task.due_at,
    v_task.title,v_code,v_task.planned_assignee_id,v_current_ref_id,p_assignee_user_id,v_target_ref_id,
    v_current_label,v_target_label,p_expected_revision
  ) returning * into v_preview;
  return private.fn_line_transport_assignment_preview_json_v1(v_preview);
end;
$$;

create function public.server_read_line_transport_assignment_preview_v1(p_actor_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare
  v_context jsonb;
  v_preview private.line_transport_assignment_previews%rowtype;
begin
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  select * into v_preview from private.line_transport_assignment_previews
    where actor_id=p_actor_id and household_id=(v_context->>'household_id')::uuid
      and actor_ref_id=(v_context->>'actor_ref_id')::uuid
    order by created_at desc,id desc limit 1;
  if not found then return null; end if;
  return private.fn_line_transport_assignment_preview_json_v1(v_preview);
end;
$$;

create function public.server_tx_decide_line_transport_assignment_v1(
  p_actor_id uuid,p_preview_id uuid,p_action text
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  v_context jsonb;
  v_preview private.line_transport_assignment_previews%rowtype;
  v_task public.task_instances%rowtype;
  v_result jsonb;
  v_code text;
begin
  if p_preview_id is null or p_action is null or p_action not in ('confirm_agreed','cancel') then
    raise exception 'INVALID_INPUT';
  end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'line-transport-assignment:'||p_actor_id::text,0));
  select * into v_preview from private.line_transport_assignment_previews
    where id=p_preview_id and actor_id=p_actor_id
      and household_id=(v_context->>'household_id')::uuid
      and actor_ref_id=(v_context->>'actor_ref_id')::uuid for update;
  if not found then raise exception 'LINE_TRANSPORT_PREVIEW_NOT_FOUND'; end if;
  if (v_preview.status='succeeded' and p_action='confirm_agreed')
    or (v_preview.status='cancelled' and p_action='cancel') then
    return private.fn_line_transport_assignment_preview_json_v1(v_preview);
  end if;
  if v_preview.status<>'draft' then raise exception 'LINE_TRANSPORT_PREVIEW_NOT_ACTIONABLE'; end if;
  if v_preview.expires_at<=clock_timestamp() then raise exception 'LINE_TRANSPORT_PREVIEW_EXPIRED'; end if;
  if p_action='cancel' then
    update private.line_transport_assignment_previews set status='cancelled',decided_at=clock_timestamp()
      where id=v_preview.id returning * into v_preview;
    return private.fn_line_transport_assignment_preview_json_v1(v_preview);
  end if;
  -- Revalidate identities and the reviewed occurrence under the task row lock.
  if not exists(select 1 from public.household_members m
    join public.domain_actor_refs ar on ar.household_id=m.household_id
      and ar.real_user_id=m.user_id and ar.actor_kind='real_user' and ar.test_context_id is null
    where m.household_id=v_preview.household_id and m.user_id=p_actor_id
      and m.member_role='adult' and ar.id=v_preview.actor_ref_id)
    or not exists(select 1 from public.household_members m
    join public.domain_actor_refs ar on ar.household_id=m.household_id
      and ar.real_user_id=m.user_id and ar.actor_kind='real_user' and ar.test_context_id is null
    where m.household_id=v_preview.household_id and m.user_id=v_preview.assignee_user_id
      and m.member_role='adult' and ar.id=v_preview.assignee_actor_ref_id) then
    raise exception 'LINE_TRANSPORT_PREVIEW_ACTOR_INVALID';
  end if;
  select * into v_task from public.task_instances ti
    where ti.id=v_preview.task_id and ti.household_id=v_preview.household_id
      and ti.test_context_id is null for update;
  if not found then raise exception 'LINE_TRANSPORT_PREVIEW_TASK_NOT_FOUND'; end if;
  select td.code into v_code from public.task_definitions td
    where td.household_id=v_preview.household_id and td.id=v_task.task_definition_id;
  if v_task.scheduled_date is distinct from v_preview.scheduled_date
    or v_task.due_at is distinct from v_preview.due_at
    or v_task.title is distinct from v_preview.title or v_code is distinct from v_preview.code
    or v_task.task_kind is distinct from 'transport' or v_task.category is distinct from v_preview.code
    or v_task.planned_assignee_id is distinct from v_preview.current_assignee_user_id
    or v_task.planned_assignee_actor_ref_id is distinct from v_preview.current_assignee_actor_ref_id then
    raise exception 'LINE_TRANSPORT_PREVIEW_STALE';
  end if;
  v_result:=private.fn_command_change_task_assignment_v1(
    v_preview.household_id,p_actor_id,v_preview.actor_ref_id,null,v_preview.task_id,
    'person',v_preview.assignee_actor_ref_id,true,v_preview.expected_revision,v_preview.operation_id,'line'
  );
  perform private.fn_reconcile_transport_role_date_v1(
    v_preview.household_id,v_preview.scheduled_date,v_preview.code,'direct_transport_assignment',v_preview.task_id
  );
  update private.line_transport_assignment_previews
    set status='succeeded',decided_at=clock_timestamp(),result=v_result
    where id=v_preview.id returning * into v_preview;
  return private.fn_line_transport_assignment_preview_json_v1(v_preview);
end;
$$;

revoke all on function public.server_tx_prepare_line_transport_assignment_v1(uuid,uuid,uuid,uuid,bigint)
  from public,anon,authenticated;
revoke all on function public.server_read_line_transport_assignment_preview_v1(uuid)
  from public,anon,authenticated;
revoke all on function public.server_tx_decide_line_transport_assignment_v1(uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function public.server_tx_prepare_line_transport_assignment_v1(uuid,uuid,uuid,uuid,bigint) to service_role;
grant execute on function public.server_read_line_transport_assignment_preview_v1(uuid) to service_role;
grant execute on function public.server_tx_decide_line_transport_assignment_v1(uuid,uuid,text) to service_role;

-- v3.3 review-fix: stable family roles, task kinds and calendar-safe manual
-- mutations.  This is intentionally forward-only; prior migrations remain an
-- immutable record of the deployed contract.

alter table public.household_members
  add column if not exists family_role text;
alter table public.household_members
  drop constraint if exists household_members_family_role_check;
alter table public.household_members
  add constraint household_members_family_role_check
  check (family_role is null or family_role in ('papa', 'mama'));

with ranked as (
  select household_id, user_id,
    row_number() over (partition by household_id order by joined_at, user_id) as position
  from public.household_members
  where family_role is null
)
update public.household_members hm
set family_role = case ranked.position when 1 then 'papa' when 2 then 'mama' else null end
from ranked where hm.household_id = ranked.household_id and hm.user_id = ranked.user_id;
create unique index if not exists household_members_one_family_role
  on public.household_members(household_id, family_role) where family_role is not null;

-- Backfill establishes existing families; this trigger gives newly created
-- households the same stable slots without ever deriving P/M at read time.
create or replace function private.fn_default_household_family_role()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.family_role is null then
    if not exists(select 1 from public.household_members where household_id=new.household_id and family_role='papa') then
      new.family_role := 'papa';
    elsif not exists(select 1 from public.household_members where household_id=new.household_id and family_role='mama') then
      new.family_role := 'mama';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists household_members_default_family_role on public.household_members;
create trigger household_members_default_family_role before insert on public.household_members
for each row execute function private.fn_default_household_family_role();

alter table public.task_definitions
  add column if not exists task_kind text not null default 'generic_once',
  add column if not exists include_in_routine_line boolean not null default true;
alter table public.task_instances
  add column if not exists task_kind text not null default 'generic_once';
alter table public.task_definitions
  drop constraint if exists task_definitions_task_kind_check;
alter table public.task_definitions add constraint task_definitions_task_kind_check
  check (task_kind in ('transport','morning_preparation','morning_chore','evening_chore','special','generic_once'));
alter table public.task_instances
  drop constraint if exists task_instances_task_kind_check;
alter table public.task_instances add constraint task_instances_task_kind_check
  check (task_kind in ('transport','morning_preparation','morning_chore','evening_chore','special','generic_once'));

create or replace function private.family_ops_task_kind(p_code text, p_category text, p_phase text, p_visibility text)
returns text language sql immutable security definer set search_path = '' as $$
  select case
    when p_code in ('dropoff','pickup') or p_category in ('dropoff','pickup') then 'transport'
    when p_code = 'morning_preparation' or p_category in ('morning_preparation','preparation') then 'morning_preparation'
    when p_phase = 'morning' then 'morning_chore'
    when p_phase = 'evening' then 'evening_chore'
    when p_visibility = 'special' then 'special'
    else 'generic_once' end
$$;

-- A prior trigger promoted every non-routine definition to `special`.  It
-- has no signal for user intent, so undo that broad legacy classification
-- before deriving the durable domain kind.
update public.task_definitions
set calendar_visibility = 'hidden'
where calendar_visibility = 'special'
  and code not in ('dropoff', 'pickup')
  and coalesce(routine_phase, 'anytime') = 'anytime';

update public.task_definitions
set task_kind = private.family_ops_task_kind(code, category, routine_phase, calendar_visibility);
update public.task_instances ti
set task_kind = coalesce(td.task_kind, private.family_ops_task_kind('', ti.category, ti.routine_phase, ti.calendar_visibility))
from public.task_definitions td
where td.household_id = ti.household_id and td.id = ti.task_definition_id;
update public.task_instances
set task_kind = private.family_ops_task_kind('', category, routine_phase, calendar_visibility)
where task_definition_id is null;

-- Unknown definitions are never implicitly promoted to a Google special.
-- Existing explicit instance-level special choices remain intact.
update public.task_definitions
set calendar_visibility = 'hidden'
where calendar_visibility = 'special' and task_kind = 'generic_once';

-- Replace the legacy broad auto-special trigger.  From this migration on,
-- only an explicit instance/definition choice may be special; the default
-- for unknown definitions is always hidden.
create or replace function private.fn_default_task_definition_calendar_visibility()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.code in ('dropoff', 'pickup') then
    new.calendar_visibility := 'transport';
  elsif new.routine_phase in ('morning', 'evening') then
    new.calendar_visibility := 'hidden';
  elsif new.calendar_visibility is null then
    new.calendar_visibility := 'hidden';
  end if;
  return new;
end $$;

create or replace function private.fn_review_fix_task_definition_domain()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.task_kind := private.family_ops_task_kind(new.code, new.category, new.routine_phase, new.calendar_visibility);
  if new.task_kind in ('transport','morning_preparation','morning_chore','evening_chore') then
    new.calendar_visibility := case when new.task_kind = 'transport' then 'transport' else 'hidden' end;
  elsif new.task_kind = 'special' then
    -- The replaced legacy trigger no longer manufactures this state: a
    -- definition that reaches here was explicitly marked special.
    new.calendar_visibility := 'special';
  elsif new.task_kind = 'generic_once' then
    new.calendar_visibility := 'hidden';
  elsif new.calendar_visibility is null then
    new.calendar_visibility := 'hidden';
  end if;
  return new;
end $$;
drop trigger if exists task_definitions_review_fix_domain on public.task_definitions;
create trigger task_definitions_review_fix_domain before insert or update of code, category, routine_phase, calendar_visibility
on public.task_definitions for each row execute function private.fn_review_fix_task_definition_domain();

create or replace function private.fn_review_fix_task_instance_domain()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_kind text; v_visibility text;
begin
  select task_kind, calendar_visibility into v_kind, v_visibility from public.task_definitions
    where household_id = new.household_id and id = new.task_definition_id;
  new.task_kind := coalesce(v_kind, private.family_ops_task_kind('', new.category, new.routine_phase, new.calendar_visibility));
  if new.task_kind in ('morning_preparation','morning_chore','evening_chore') then new.calendar_visibility := 'hidden';
  elsif new.task_kind = 'transport' then new.calendar_visibility := 'transport';
  elsif new.calendar_visibility is null then new.calendar_visibility := coalesce(v_visibility, 'hidden'); end if;
  return new;
end $$;
drop trigger if exists task_instances_review_fix_domain on public.task_instances;
create trigger task_instances_review_fix_domain before insert or update of task_definition_id, category, routine_phase, calendar_visibility
on public.task_instances for each row execute function private.fn_review_fix_task_instance_domain();

create or replace function private.fn_review_fix_special_hide_cleanup()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.calendar_visibility='special' and new.calendar_visibility='hidden' then
    update private.family_ops_calendar_mirrors set desired_action='delete',sync_state='pending',next_attempt_at=now(),lease_token=null,lease_until=null,updated_at=now()
    where household_id=new.household_id and projection_key='special:'||new.id::text;
  end if;
  return new;
end $$;
drop trigger if exists task_instances_review_fix_special_hide_cleanup on public.task_instances;
create trigger task_instances_review_fix_special_hide_cleanup after update of calendar_visibility on public.task_instances for each row execute function private.fn_review_fix_special_hide_cleanup();

create or replace function private.family_ops_member_token(p_household_id uuid, p_user_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case when p_user_id is null then '—' else coalesce((
    select case family_role when 'papa' then 'P' when 'mama' then 'M' else null end
    from public.household_members where household_id = p_household_id and user_id = p_user_id
  ), '未') end
$$;

-- Full create payload is hashed before the legacy create RPC claims its
-- receipt.  A retry that changes Google-affecting fields is rejected.
create or replace function public.server_tx_create_task_with_calendar(
  p_actor_id uuid, p_operation_id uuid, p_title text, p_category text,
  p_scheduled_date date, p_due_local_time time, p_calendar_end_local_time time,
  p_calendar_visibility text, p_planned_assignee_user_id uuid, p_completion_mode text,
  p_routine_phase text, p_subtasks jsonb
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_hash text; v_receipt record; v_household uuid; v_task_id uuid; v_result jsonb; v_subtask jsonb;
begin
  if coalesce(p_calendar_visibility, 'hidden') not in ('hidden','special') then raise exception 'INVALID_INPUT'; end if;
  if p_calendar_end_local_time is not null and (p_due_local_time is null or p_calendar_end_local_time <= p_due_local_time) then raise exception 'INVALID_INPUT'; end if;
  v_hash := encode(sha256(convert_to(jsonb_build_object('title',p_title,'category',p_category,'date',p_scheduled_date,'due',p_due_local_time,'end',p_calendar_end_local_time,'visibility',p_calendar_visibility,'assignee',p_planned_assignee_user_id,'completion',p_completion_mode,'phase',p_routine_phase,'subtasks',p_subtasks)::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash) values(p_actor_id,p_operation_id,'create-task-calendar-v2',v_hash) on conflict(actor_id,operation_id) do nothing;
  if not found then select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash <> v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return v_receipt.result_payload; end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id;
  if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,due_at,calendar_ends_at,calendar_visibility,planned_assignee_id,completion_mode,status,source,created_by)
  values(v_household,'manual',btrim(p_title),coalesce(nullif(btrim(p_category),''),'other'),coalesce(p_routine_phase,'anytime'),p_scheduled_date,
    case when p_due_local_time is null then null else (p_scheduled_date::text||' '||p_due_local_time::text)::timestamp at time zone 'Asia/Tokyo' end,
    case when p_calendar_end_local_time is null then null else (p_scheduled_date::text||' '||p_calendar_end_local_time::text)::timestamp at time zone 'Asia/Tokyo' end,
    coalesce(p_calendar_visibility,'hidden'),p_planned_assignee_user_id,p_completion_mode,'todo','manual',p_actor_id) returning id into v_task_id;
  if p_completion_mode='subtasks' and p_subtasks is not null then
    for v_subtask in select * from jsonb_array_elements(p_subtasks) loop
      insert into public.task_subtask_instances(household_id,task_instance_id,source_definition_id,title,required,sort_order)
      values(v_household,v_task_id,null,btrim(v_subtask->>'title'),coalesce((v_subtask->>'required')::boolean,true),coalesce((v_subtask->>'sort_order')::int,0));
    end loop;
  end if;
  v_result:=jsonb_build_object('task_id',v_task_id);
  update private.mutation_receipts set result_type='task_instance',result_id=v_task_id,result_payload=v_result where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end $$;

create or replace function public.server_tx_edit_task_with_calendar(
  p_actor_id uuid,p_operation_id uuid,p_task_id uuid,p_title text,p_scheduled_date date,p_due_local_time time,
  p_calendar_end_local_time time,p_category text,p_planned_assignee_user_id uuid,p_calendar_visibility text
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_hash text; v_receipt record; v_household uuid; v_task public.task_instances%rowtype; v_result jsonb;
begin
  v_hash:=encode(sha256(convert_to(jsonb_build_object('task',p_task_id,'title',p_title,'date',p_scheduled_date,'due',p_due_local_time,'end',p_calendar_end_local_time,'category',p_category,'assignee',p_planned_assignee_user_id,'visibility',p_calendar_visibility)::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash) values(p_actor_id,p_operation_id,'edit-task-calendar-v2',v_hash) on conflict(actor_id,operation_id) do nothing;
  if not found then select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update; if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return v_receipt.result_payload; end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id; if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select * into v_task from public.task_instances where household_id=v_household and id=p_task_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if; if v_task.origin<>'manual' or v_task.status not in ('todo','in_progress') then raise exception 'TASK_TERMINAL'; end if;
  if coalesce(p_calendar_visibility,v_task.calendar_visibility) not in ('hidden','special') then raise exception 'INVALID_INPUT'; end if;
  if p_calendar_end_local_time is not null and (p_due_local_time is null or p_calendar_end_local_time<=p_due_local_time) then raise exception 'INVALID_INPUT'; end if;
  update public.task_instances set title=coalesce(nullif(btrim(p_title),''),title), scheduled_date=coalesce(p_scheduled_date,scheduled_date), category=coalesce(nullif(btrim(p_category),''),category),
    due_at=case when p_due_local_time is null then null else (coalesce(p_scheduled_date,scheduled_date)::text||' '||p_due_local_time::text)::timestamp at time zone 'Asia/Tokyo' end,
    calendar_ends_at=case when p_calendar_end_local_time is null then null else (coalesce(p_scheduled_date,scheduled_date)::text||' '||p_calendar_end_local_time::text)::timestamp at time zone 'Asia/Tokyo' end,
    planned_assignee_id=p_planned_assignee_user_id,calendar_visibility=coalesce(p_calendar_visibility,calendar_visibility)
  where household_id=v_household and id=p_task_id;
  insert into public.task_events(household_id,task_instance_id,actor_id,event_type,source,idempotency_key) values(v_household,p_task_id,p_actor_id,'edited','pwa',p_operation_id::text||':edited');
  v_result:=jsonb_build_object('ok',true,'task_id',p_task_id); update private.mutation_receipts set result_type='task_instance',result_id=p_task_id,result_payload=v_result where actor_id=p_actor_id and operation_id=p_operation_id; return v_result;
end $$;

revoke all on function private.family_ops_task_kind(text,text,text,text) from public,anon,authenticated;
revoke all on function private.fn_default_household_family_role() from public,anon,authenticated;
revoke all on function private.fn_review_fix_task_definition_domain() from public,anon,authenticated;
revoke all on function private.fn_review_fix_task_instance_domain() from public,anon,authenticated;
revoke all on function private.fn_review_fix_special_hide_cleanup() from public,anon,authenticated;
revoke all on function public.server_tx_create_task_with_calendar(uuid,uuid,text,text,date,time,time,text,uuid,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.server_tx_edit_task_with_calendar(uuid,uuid,uuid,text,date,time,time,text,uuid,text) from public,anon,authenticated;
grant execute on function public.server_tx_create_task_with_calendar(uuid,uuid,text,text,date,time,time,text,uuid,text,text,jsonb) to service_role;
grant execute on function public.server_tx_edit_task_with_calendar(uuid,uuid,uuid,text,date,time,time,text,uuid,text) to service_role;

create or replace function public.server_tx_set_routine_definition_options(
  p_actor_id uuid,p_operation_id uuid,p_task_definition_id uuid,p_enabled boolean,p_include_in_routine_line boolean
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_household uuid; v_receipt record; v_hash text; v_result jsonb;
begin
  v_hash:=encode(sha256(convert_to(jsonb_build_object('definition',p_task_definition_id,'enabled',p_enabled,'line',p_include_in_routine_line)::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash) values(p_actor_id,p_operation_id,'routine-definition-options-v1',v_hash) on conflict(actor_id,operation_id) do nothing;
  if not found then select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id; if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return v_receipt.result_payload; end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id; if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  update public.task_definitions set is_active=p_enabled,include_in_routine_line=p_include_in_routine_line where id=p_task_definition_id and household_id=v_household and task_kind in ('morning_chore','evening_chore');
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if not p_include_in_routine_line then
    delete from public.routine_checkin_session_items si
    using public.routine_checkin_sessions s, public.task_instances ti
    where si.household_id=v_household and si.session_id=s.id and si.task_instance_id=ti.id
      and ti.task_definition_id=p_task_definition_id and s.status='open'
      and s.scheduled_date >= (now() at time zone 'Asia/Tokyo')::date;
  end if;
  if not p_enabled then
    update public.recurrence_rules set active=false,effective_to=(now() at time zone 'Asia/Tokyo')::date-1 where household_id=v_household and task_definition_id=p_task_definition_id and active;
    delete from public.task_instances where household_id=v_household and task_definition_id=p_task_definition_id and scheduled_date >= (now() at time zone 'Asia/Tokyo')::date and status='todo';
  end if;
  v_result:=jsonb_build_object('ok',true); update private.mutation_receipts set result_payload=v_result,result_type='task_definition',result_id=p_task_definition_id where actor_id=p_actor_id and operation_id=p_operation_id; return v_result;
end $$;
revoke all on function public.server_tx_set_routine_definition_options(uuid,uuid,uuid,boolean,boolean) from public,anon,authenticated;
grant execute on function public.server_tx_set_routine_definition_options(uuid,uuid,uuid,boolean,boolean) to service_role;

create or replace function public.server_tx_set_family_calendar_target(p_actor_id uuid,p_operation_id uuid,p_calendar_connection_id uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_household uuid; v_old uuid; v_result jsonb; v_hash text; v_receipt record;
begin
  v_hash:=encode(sha256(convert_to(jsonb_build_object('calendar_connection_id',p_calendar_connection_id)::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash) values(p_actor_id,p_operation_id,'set-family-calendar-target-v1',v_hash) on conflict(actor_id,operation_id) do nothing;
  if not found then select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update; if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return v_receipt.result_payload; end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id; if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  if not exists(select 1 from public.calendar_connections where id=p_calendar_connection_id and household_id=v_household and provider='google' and active and not reauth_required) then raise exception 'INVALID_INPUT'; end if;
  select id into v_old from public.calendar_connections where household_id=v_household and is_family_write_target for update;
  update public.calendar_connections set is_family_write_target=false where household_id=v_household and is_family_write_target;
  update public.calendar_connections set is_family_write_target=true where id=p_calendar_connection_id;
  perform public.server_tx_reconcile_family_ops_calendar(v_household);
  v_result:=jsonb_build_object('ok',true,'previous_calendar_connection_id',v_old,'calendar_connection_id',p_calendar_connection_id);
  update private.mutation_receipts set result_payload=v_result,result_type='calendar_connection',result_id=p_calendar_connection_id where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end $$;
revoke all on function public.server_tx_set_family_calendar_target(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_set_family_calendar_target(uuid,uuid,uuid) to service_role;

create or replace function public.server_tx_set_family_role(p_actor_id uuid,p_operation_id uuid,p_user_id uuid,p_family_role text)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_household uuid; v_hash text; v_receipt record; v_result jsonb;
begin
  v_hash:=encode(sha256(convert_to(jsonb_build_object('user_id',p_user_id,'family_role',p_family_role)::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash) values(p_actor_id,p_operation_id,'set-family-role-v1',v_hash) on conflict(actor_id,operation_id) do nothing;
  if not found then select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update; if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return v_receipt.result_payload; end if;
  if p_family_role not in ('papa','mama') then raise exception 'INVALID_INPUT'; end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id; if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  if not exists(select 1 from public.household_members where household_id=v_household and user_id=p_user_id) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  update public.household_members set family_role=null where household_id=v_household and family_role=p_family_role;
  update public.household_members set family_role=p_family_role where household_id=v_household and user_id=p_user_id;
  v_result:=jsonb_build_object('ok',true,'user_id',p_user_id,'family_role',p_family_role);
  update private.mutation_receipts set result_payload=v_result,result_type='household_member',result_id=p_user_id where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end $$;
revoke all on function public.server_tx_set_family_role(uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.server_tx_set_family_role(uuid,uuid,uuid,text) to service_role;

-- LINE sessions reuse canonical task instances, but definition-level opt-out
-- removes only the LINE checklist item; Today and History remain untouched.
create or replace function private.fn_get_or_create_routine_session(p_household_id uuid,p_session_type text,p_scheduled_date date,p_assignee_id uuid,p_phase text,p_anchor_task_instance_id uuid)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare v_candidate_ids uuid[]; v_session_id uuid; v_status text;
begin
  if p_assignee_id is null then return null; end if;
  select coalesce(array_agg(id),'{}') into v_candidate_ids from (
    select id from public.task_instances where household_id=p_household_id and id=p_anchor_task_instance_id and status in ('todo','in_progress')
    union
    select id from public.task_instances where household_id=p_household_id and scheduled_date=p_scheduled_date
      and planned_assignee_id=p_assignee_id and status in ('todo','in_progress')
      and ((p_phase='morning' and task_kind in ('morning_preparation','morning_chore')) or (p_phase='evening' and task_kind='evening_chore'))
      and (p_anchor_task_instance_id is null or id<>p_anchor_task_instance_id)
  ) candidates;
  if array_length(v_candidate_ids,1) is null then return null; end if;
  select id,status into v_session_id,v_status from public.routine_checkin_sessions where household_id=p_household_id and session_type=p_session_type and scheduled_date=p_scheduled_date and assignee_id=p_assignee_id for update;
  if not found then insert into public.routine_checkin_sessions(household_id,session_type,scheduled_date,assignee_id,status,assignment_generation) values(p_household_id,p_session_type,p_scheduled_date,p_assignee_id,'open',1) returning id into v_session_id;
  elsif v_status='superseded' then update public.routine_checkin_sessions set status='open',superseded_at=null,opened_at=now(),submitted_at=null,assignment_generation=assignment_generation+1 where id=v_session_id; end if;
  insert into public.routine_checkin_session_items(household_id,session_id,task_instance_id,display_order)
  select p_household_id,v_session_id,cid,row_number() over(order by td.sort_order,ti.created_at)
  from unnest(v_candidate_ids) cid join public.task_instances ti on ti.household_id=p_household_id and ti.id=cid
  left join public.task_definitions td on td.household_id=p_household_id and td.id=ti.task_definition_id
  where coalesce(td.include_in_routine_line,true)
  on conflict(session_id,task_instance_id) do nothing;
  return v_session_id;
end $$;

-- Switching the write target is a two-phase outbox operation: retain an
-- explicit deletion job for every old provider event before its canonical
-- mirror is pointed at the newly selected family calendar.  This prevents
-- stale Family Ops events in the previous calendar without making the
-- household setting mutation depend on Google availability.
create table if not exists private.family_ops_calendar_target_deletions (
  id uuid primary key default gen_random_uuid(), household_id uuid not null references public.households(id) on delete cascade,
  calendar_connection_id uuid not null references public.calendar_connections(id) on delete cascade,
  projection_key text not null, provider_event_id text not null,
  sync_state text not null default 'pending' check (sync_state in ('pending','processing','deleted','failed')),
  attempts integer not null default 0, next_attempt_at timestamptz not null default now(),
  lease_token uuid, lease_until timestamptz, last_error text, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (calendar_connection_id, projection_key, provider_event_id)
);
revoke all on private.family_ops_calendar_target_deletions from public, anon, authenticated;
create index if not exists family_ops_calendar_target_deletions_claim_idx on private.family_ops_calendar_target_deletions(sync_state,next_attempt_at)
  where sync_state in ('pending','failed');

create or replace function public.server_tx_set_family_calendar_target(p_actor_id uuid,p_operation_id uuid,p_calendar_connection_id uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_household uuid; v_old uuid; v_result jsonb; v_hash text; v_receipt record;
begin
  v_hash:=encode(sha256(convert_to(jsonb_build_object('calendar_connection_id',p_calendar_connection_id)::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash) values(p_actor_id,p_operation_id,'set-family-calendar-target-v1',v_hash) on conflict(actor_id,operation_id) do nothing;
  if not found then select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update; if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return v_receipt.result_payload; end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id; if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  if not exists(select 1 from public.calendar_connections where id=p_calendar_connection_id and household_id=v_household and provider='google' and active and not reauth_required) then raise exception 'INVALID_INPUT'; end if;
  select id into v_old from public.calendar_connections where household_id=v_household and is_family_write_target for update;
  if v_old is distinct from p_calendar_connection_id and v_old is not null then
    insert into private.family_ops_calendar_target_deletions(household_id,calendar_connection_id,projection_key,provider_event_id)
    select household_id,calendar_connection_id,projection_key,provider_event_id from private.family_ops_calendar_mirrors
    where household_id=v_household and calendar_connection_id=v_old and provider_event_id is not null
    on conflict(calendar_connection_id,projection_key,provider_event_id) do update set sync_state='pending',next_attempt_at=now(),lease_token=null,lease_until=null,last_error=null,updated_at=now();
  end if;
  update public.calendar_connections set is_family_write_target=false where household_id=v_household and is_family_write_target;
  update public.calendar_connections set is_family_write_target=true where id=p_calendar_connection_id;
  perform public.server_tx_reconcile_family_ops_calendar(v_household);
  v_result:=jsonb_build_object('ok',true,'previous_calendar_connection_id',v_old,'calendar_connection_id',p_calendar_connection_id);
  update private.mutation_receipts set result_payload=v_result,result_type='calendar_connection',result_id=p_calendar_connection_id where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end $$;

create or replace function public.server_tx_claim_family_ops_calendar_target_deletion(p_worker_id text,p_lease_seconds integer default 120)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_job private.family_ops_calendar_target_deletions%rowtype; v_lease uuid:=gen_random_uuid();
begin
  if coalesce(p_worker_id,'')='' then raise exception 'INVALID_INPUT'; end if;
  select * into v_job from private.family_ops_calendar_target_deletions
    where (sync_state in ('pending','failed') and next_attempt_at<=now()) or (sync_state='processing' and lease_until<now())
    order by next_attempt_at,created_at for update skip locked limit 1;
  if not found then return null; end if;
  update private.family_ops_calendar_target_deletions set sync_state='processing',lease_token=v_lease,lease_until=now()+make_interval(secs=>greatest(coalesce(p_lease_seconds,120),30)),attempts=attempts+1,updated_at=now() where id=v_job.id returning * into v_job;
  return jsonb_build_object('id',v_job.id,'household_id',v_job.household_id,'calendar_connection_id',v_job.calendar_connection_id,'projection_key',v_job.projection_key,'provider_event_id',v_job.provider_event_id,'lease_token',v_lease);
end $$;
create or replace function public.server_tx_complete_family_ops_calendar_target_deletion(p_id uuid,p_lease_token uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
begin
  update private.family_ops_calendar_target_deletions set sync_state='deleted',lease_token=null,lease_until=null,last_error=null,updated_at=now() where id=p_id and sync_state='processing' and lease_token=p_lease_token;
  if not found then raise exception 'GOOGLE_SYNC_LEASE_LOST'; end if; return jsonb_build_object('ok',true);
end $$;
create or replace function public.server_tx_fail_family_ops_calendar_target_deletion(p_id uuid,p_lease_token uuid,p_error text)
returns jsonb language plpgsql security invoker set search_path = '' as $$
begin
  update private.family_ops_calendar_target_deletions set sync_state='failed',lease_token=null,lease_until=null,last_error=left(coalesce(p_error,'unknown'),1000),next_attempt_at=now()+make_interval(secs=>(2^least(attempts,6))::integer*30),updated_at=now() where id=p_id and sync_state='processing' and lease_token=p_lease_token;
  if not found then raise exception 'GOOGLE_SYNC_LEASE_LOST'; end if; return jsonb_build_object('ok',true);
end $$;
revoke all on function public.server_tx_claim_family_ops_calendar_target_deletion(text,integer) from public,anon,authenticated;
revoke all on function public.server_tx_complete_family_ops_calendar_target_deletion(uuid,uuid) from public,anon,authenticated;
revoke all on function public.server_tx_fail_family_ops_calendar_target_deletion(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.server_tx_claim_family_ops_calendar_target_deletion(text,integer) to service_role;
grant execute on function public.server_tx_complete_family_ops_calendar_target_deletion(uuid,uuid) to service_role;
grant execute on function public.server_tx_fail_family_ops_calendar_target_deletion(uuid,uuid,text) to service_role;

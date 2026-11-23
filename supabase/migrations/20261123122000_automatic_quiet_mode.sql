-- Issue #196: quiet delivery is personal, and reflects deliberate actions only.
-- The snapshot is the beginning of the current Tokyo day: a return to activity
-- takes effect the following morning, not halfway through a notification day.
alter table public.notification_preferences
  add column quiet_mode text not null default 'auto' check (quiet_mode in ('auto','quiet','normal'));

create index quiet_activity_task_events_idx on public.task_events (actor_id,created_at desc)
  where test_context_id is null;
create index quiet_activity_mutation_receipts_idx on private.mutation_receipts (actor_id,created_at desc)
  where test_context_id is null;
create index quiet_activity_canonical_receipts_idx on private.canonical_operation_receipts (operator_user_id,created_at desc)
  where test_context_id is null and completed_at is not null;
create index quiet_activity_line_inbox_idx on private.webhook_inbox (source_external_user_id,received_at desc)
  where provider='line' and payload->>'type' in ('message','postback');

create function private.fn_recipient_quiet_mode_v1(p_household uuid,p_user uuid,p_at timestamptz)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare preference text; day_start timestamptz; active boolean;
begin
  select n.quiet_mode into preference from public.notification_preferences n
    where n.household_id=p_household and n.user_id=p_user;
  -- Unknown or non-member recipients retain existing delivery behaviour.
  if preference is null or p_at is null then return false; end if;
  if preference='quiet' then return true; end if;
  if preference='normal' then return false; end if;
  day_start:=date_trunc('day',p_at at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo';
  select exists (
    select 1 from private.line_user_links l join private.webhook_inbox w
      on w.provider='line' and w.source_external_user_id=l.line_user_id
      and w.payload->>'type' in ('message','postback')
      and w.received_at>=l.linked_at and w.received_at>=day_start-interval '7 days' and w.received_at<day_start
    where l.household_id=p_household and l.user_id=p_user and l.status='active'
    union all
    select 1 from public.task_events e where e.household_id=p_household and e.actor_id=p_user
      and e.test_context_id is null and e.source in ('pwa','line','routine_editor')
      and e.event_type in ('completed','skipped','subtask_completed','subtask_uncompleted','work_progress_recorded','completion_reverted','assignment_changed')
      and e.created_at>=day_start-interval '7 days' and e.created_at<day_start
    union all
    select 1 from private.mutation_receipts r where r.actor_id=p_user and r.test_context_id is null
      and r.result_payload is not null and r.created_at>=day_start-interval '7 days' and r.created_at<day_start
    union all
    select 1 from private.canonical_operation_receipts c join public.domain_actor_refs ar
      on ar.household_id=c.household_id and ar.id=c.actor_ref_id and ar.actor_kind='real_user'
      and ar.real_user_id=p_user and ar.test_context_id is null
    where c.household_id=p_household and c.operator_user_id=p_user and c.test_context_id is null
      and c.completed_at is not null and c.created_at>=day_start-interval '7 days' and c.created_at<day_start
      and (c.action_type like 'shopping.%' or c.action_type in ('assignment.review','checklist.complete','checklist.undo','task.progress.record'))
  ) into active;
  return not active;
end $$;
revoke all on function private.fn_recipient_quiet_mode_v1(uuid,uuid,timestamptz) from public,anon,authenticated,service_role;

create or replace function public.server_tx_update_reminder_settings(
  p_actor_id uuid, p_operation_id uuid, p_settings jsonb
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare h uuid; hash text; r private.mutation_receipts%rowtype; key text; result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or jsonb_typeof(p_settings)<>'object' then
    raise exception 'INVALID_INPUT';
  end if;
  for key in select jsonb_object_keys(p_settings) loop
    if key in ('default_timed_reminders','default_all_day_reminders') then
      if not public.is_valid_reminder_list(p_settings->key) then raise exception 'INVALID_INPUT'; end if;
    elsif key='schedule_line_with_push' then
      if jsonb_typeof(p_settings->key)<>'boolean' then raise exception 'INVALID_INPUT'; end if;
    elsif key='quiet_mode' then
      if jsonb_typeof(p_settings->key)<>'string' or p_settings->>key not in ('auto','quiet','normal') then raise exception 'INVALID_INPUT'; end if;
    elsif key='morning_nudge_local_time' then
      -- null = off; otherwise a time between 05:00 and 10:59.
      if jsonb_typeof(p_settings->key)<>'null' and (jsonb_typeof(p_settings->key)<>'string'
        or (p_settings->>key) !~ '^(0[5-9]|10):[0-5][0-9]$') then raise exception 'INVALID_INPUT'; end if;
    else
      raise exception 'INVALID_INPUT';
    end if;
  end loop;
  select household_id into h from public.household_members where user_id=p_actor_id;
  if h is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  hash:=encode(sha256(convert_to('update-reminder-settings|'||p_settings::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
  values(p_actor_id,p_operation_id,'update-reminder-settings',hash) on conflict(actor_id,operation_id) do nothing;
  if not found then
    select * into r from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if r.request_hash<>hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return r.result_payload;
  end if;
  update public.households set
    default_timed_reminders=coalesce(p_settings->'default_timed_reminders',default_timed_reminders),
    default_all_day_reminders=coalesce(p_settings->'default_all_day_reminders',default_all_day_reminders)
  where id=h;
  if p_settings ? 'morning_nudge_local_time' then
    update public.households set morning_nudge_local_time=nullif(p_settings->>'morning_nudge_local_time','')::time where id=h;
  end if;
  if p_settings ? 'schedule_line_with_push' then
    update public.notification_preferences set schedule_line_with_push=(p_settings->>'schedule_line_with_push')::boolean
    where household_id=h and user_id=p_actor_id;
  end if;
  if p_settings ? 'quiet_mode' then
    update public.notification_preferences set quiet_mode=p_settings->>'quiet_mode'
    where household_id=h and user_id=p_actor_id;
  end if;
  result:=jsonb_build_object('ok',true);
  update private.mutation_receipts set result_type='reminder_settings',result_id=h,result_payload=result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return result;
end $$;

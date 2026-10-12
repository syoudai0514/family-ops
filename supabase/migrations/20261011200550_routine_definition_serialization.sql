-- Definition changes and materialization must share their first row lock.
-- Otherwise a worker can read is_active=true, wait until a pause has scanned
-- existing occurrences, and then insert a new todo for the stopped routine.
-- Keep the existing command bodies (validation, receipts and projections) and
-- acquire definition -> rule -> occurrence locks before delegating to them.
-- Non-key row locks serialize active/template changes while allowing the
-- foreign-key KEY SHARE checks performed by independent task insertions.

alter function private.materialize_recurrence_rule(uuid,uuid,date,date)
  rename to routine_materialize_recurrence_body_v1;

create function private.materialize_recurrence_rule(
  p_household_id uuid,p_rule_id uuid,p_from_date date,p_to_date date
) returns void language plpgsql security invoker set search_path='' as $$
declare v_definition_id uuid;
begin
  select task_definition_id into v_definition_id from public.recurrence_rules
  where household_id=p_household_id and id=p_rule_id;
  if not found then return; end if;

  perform 1 from public.task_definitions
  where household_id=p_household_id and id=v_definition_id for no key update;
  if not found then return; end if;
  perform 1 from public.recurrence_rules
  where household_id=p_household_id and id=p_rule_id for no key update;
  if not found then return; end if;

  -- The body reads the committed active flag and snapshots only after the
  -- definition lock is acquired, including when this call waited for a pause.
  perform private.routine_materialize_recurrence_body_v1(
    p_household_id,p_rule_id,p_from_date,p_to_date
  );
end $$;
revoke all on function private.materialize_recurrence_rule(uuid,uuid,date,date) from public,anon,authenticated;
grant execute on function private.materialize_recurrence_rule(uuid,uuid,date,date) to service_role;
revoke all on function private.routine_materialize_recurrence_body_v1(uuid,uuid,date,date) from public,anon,authenticated;
grant execute on function private.routine_materialize_recurrence_body_v1(uuid,uuid,date,date) to service_role;

alter function public.server_tx_change_recurrence(uuid,uuid,uuid,int,text,text,uuid,time,int,date)
  set schema private;
alter function private.server_tx_change_recurrence(uuid,uuid,uuid,int,text,text,uuid,time,int,date)
  rename to routine_change_recurrence_body_v1;

create function public.server_tx_change_recurrence(
  p_actor_id uuid,p_operation_id uuid,p_task_definition_id uuid,p_weekday int,
  p_slot_key text,p_assignee_strategy text,p_planned_assignee_user_id uuid,
  p_scheduled_local_time time,p_conflict_window_minutes int,p_effective_from date
) returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  perform 1 from public.task_definitions d
  where d.id=p_task_definition_id and exists(
    select 1 from public.household_members m
    where m.user_id=p_actor_id and m.household_id=d.household_id
  ) for no key update of d;
  return private.routine_change_recurrence_body_v1(
    p_actor_id,p_operation_id,p_task_definition_id,p_weekday,p_slot_key,
    p_assignee_strategy,p_planned_assignee_user_id,p_scheduled_local_time,
    p_conflict_window_minutes,p_effective_from
  );
end $$;
revoke all on function public.server_tx_change_recurrence(uuid,uuid,uuid,int,text,text,uuid,time,int,date) from public,anon,authenticated;
grant execute on function public.server_tx_change_recurrence(uuid,uuid,uuid,int,text,text,uuid,time,int,date) to service_role;
revoke all on function private.routine_change_recurrence_body_v1(uuid,uuid,uuid,int,text,text,uuid,time,int,date) from public,anon,authenticated;
grant execute on function private.routine_change_recurrence_body_v1(uuid,uuid,uuid,int,text,text,uuid,time,int,date) to service_role;

alter function public.server_tx_deactivate_recurrence(uuid,uuid,uuid,int,text)
  set schema private;
alter function private.server_tx_deactivate_recurrence(uuid,uuid,uuid,int,text)
  rename to routine_deactivate_recurrence_body_v1;

create function public.server_tx_deactivate_recurrence(
  p_actor_id uuid,p_operation_id uuid,p_task_definition_id uuid,p_weekday int,
  p_slot_key text default null
) returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  perform 1 from public.task_definitions d
  where d.id=p_task_definition_id and exists(
    select 1 from public.household_members m
    where m.user_id=p_actor_id and m.household_id=d.household_id
  ) for no key update of d;
  return private.routine_deactivate_recurrence_body_v1(
    p_actor_id,p_operation_id,p_task_definition_id,p_weekday,p_slot_key
  );
end $$;
revoke all on function public.server_tx_deactivate_recurrence(uuid,uuid,uuid,int,text) from public,anon,authenticated;
grant execute on function public.server_tx_deactivate_recurrence(uuid,uuid,uuid,int,text) to service_role;
revoke all on function private.routine_deactivate_recurrence_body_v1(uuid,uuid,uuid,int,text) from public,anon,authenticated;
grant execute on function private.routine_deactivate_recurrence_body_v1(uuid,uuid,uuid,int,text) to service_role;

alter function public.server_tx_replace_recurrence_schedule(uuid,uuid,jsonb)
  set schema private;
alter function private.server_tx_replace_recurrence_schedule(uuid,uuid,jsonb)
  rename to routine_replace_recurrence_body_v1;

create function public.server_tx_replace_recurrence_schedule(
  p_actor_id uuid,p_operation_id uuid,p_replacements jsonb
) returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  if jsonb_typeof(p_replacements)='array' then
    -- Lock the complete target set in a stable order before the command's
    -- caller-supplied order reaches any rule or occurrence.
    perform 1 from public.task_definitions d
    where exists(
      select 1 from public.household_members m
      where m.user_id=p_actor_id and m.household_id=d.household_id
    ) and exists(
      select 1 from jsonb_array_elements(p_replacements) r
      where nullif(r->>'task_definition_id','')::uuid=d.id
    ) order by d.household_id,d.id for no key update of d;
  end if;
  return private.routine_replace_recurrence_body_v1(p_actor_id,p_operation_id,p_replacements);
end $$;
revoke all on function public.server_tx_replace_recurrence_schedule(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_replace_recurrence_schedule(uuid,uuid,jsonb) to service_role;
revoke all on function private.routine_replace_recurrence_body_v1(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function private.routine_replace_recurrence_body_v1(uuid,uuid,jsonb) to service_role;

-- Definition edits and options use the same entry lock as schedule commands,
-- before their mutation receipt. This also avoids reversed receipt/definition
-- lock order when an operation id is accidentally reused across commands.
alter function public.server_tx_edit_task_definition(uuid,uuid,uuid,text,text,text,text,int)
  set schema private;
alter function private.server_tx_edit_task_definition(uuid,uuid,uuid,text,text,text,text,int)
  rename to routine_edit_definition_body_v1;
create function public.server_tx_edit_task_definition(
  p_actor_id uuid,p_operation_id uuid,p_task_definition_id uuid,p_title text,
  p_category text,p_routine_phase text,p_completion_mode text,p_sort_order int
) returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  perform 1 from public.task_definitions d
  where d.id=p_task_definition_id and exists(
    select 1 from public.household_members m
    where m.user_id=p_actor_id and m.household_id=d.household_id
  ) for no key update of d;
  return private.routine_edit_definition_body_v1(
    p_actor_id,p_operation_id,p_task_definition_id,p_title,p_category,
    p_routine_phase,p_completion_mode,p_sort_order
  );
end $$;
revoke all on function public.server_tx_edit_task_definition(uuid,uuid,uuid,text,text,text,text,int) from public,anon,authenticated;
grant execute on function public.server_tx_edit_task_definition(uuid,uuid,uuid,text,text,text,text,int) to service_role;
revoke all on function private.routine_edit_definition_body_v1(uuid,uuid,uuid,text,text,text,text,int) from public,anon,authenticated;
grant execute on function private.routine_edit_definition_body_v1(uuid,uuid,uuid,text,text,text,text,int) to service_role;

alter function public.server_tx_set_routine_definition_options(uuid,uuid,uuid,boolean,boolean,text)
  set schema private;
alter function private.server_tx_set_routine_definition_options(uuid,uuid,uuid,boolean,boolean,text)
  rename to routine_definition_options_body_v1;
create function public.server_tx_set_routine_definition_options(
  p_actor_id uuid,p_operation_id uuid,p_task_definition_id uuid,p_enabled boolean,
  p_include_in_routine_line boolean,p_default_expectation text default null
) returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  perform 1 from public.task_definitions d
  where d.id=p_task_definition_id and exists(
    select 1 from public.household_members m
    where m.user_id=p_actor_id and m.household_id=d.household_id
  ) for no key update of d;
  return private.routine_definition_options_body_v1(
    p_actor_id,p_operation_id,p_task_definition_id,p_enabled,
    p_include_in_routine_line,p_default_expectation
  );
end $$;
revoke all on function public.server_tx_set_routine_definition_options(uuid,uuid,uuid,boolean,boolean,text) from public,anon,authenticated;
grant execute on function public.server_tx_set_routine_definition_options(uuid,uuid,uuid,boolean,boolean,text) to service_role;
revoke all on function private.routine_definition_options_body_v1(uuid,uuid,uuid,boolean,boolean,text) from public,anon,authenticated;
grant execute on function private.routine_definition_options_body_v1(uuid,uuid,uuid,boolean,boolean,text) to service_role;

-- These existing entry points mutate rules and occurrences before calling
-- materialization. Prelock their entire definition set in the same UUID order
-- as the daily worker, including transport's period and same-start editors.
alter function public.server_tx_save_transport_template(uuid,uuid,date,jsonb)
  set schema private;
alter function private.server_tx_save_transport_template(uuid,uuid,date,jsonb)
  rename to routine_save_transport_template_body_v1;
create function public.server_tx_save_transport_template(
  p_actor_id uuid,p_operation_id uuid,p_valid_from date,p_days jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
begin
  perform 1 from public.task_definitions d
  where d.code in ('dropoff','pickup') and exists(
    select 1 from public.household_members m
    where m.user_id=p_actor_id and m.household_id=d.household_id
  ) order by d.household_id,d.id for no key update of d;
  return private.routine_save_transport_template_body_v1(p_actor_id,p_operation_id,p_valid_from,p_days);
end $$;
revoke all on function public.server_tx_save_transport_template(uuid,uuid,date,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_save_transport_template(uuid,uuid,date,jsonb) to service_role;
revoke all on function private.routine_save_transport_template_body_v1(uuid,uuid,date,jsonb) from public,anon,authenticated;
grant execute on function private.routine_save_transport_template_body_v1(uuid,uuid,date,jsonb) to service_role;

alter function public.server_tx_update_transport_template_same_start_v1(uuid,uuid,date,jsonb)
  set schema private;
alter function private.server_tx_update_transport_template_same_start_v1(uuid,uuid,date,jsonb)
  rename to routine_update_transport_template_body_v1;
create function public.server_tx_update_transport_template_same_start_v1(
  p_actor_id uuid,p_operation_id uuid,p_valid_from date,p_days jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
begin
  perform 1 from public.task_definitions d
  where d.code in ('dropoff','pickup') and exists(
    select 1 from public.household_members m
    where m.user_id=p_actor_id and m.household_id=d.household_id
  ) order by d.household_id,d.id for no key update of d;
  return private.routine_update_transport_template_body_v1(p_actor_id,p_operation_id,p_valid_from,p_days);
end $$;
revoke all on function public.server_tx_update_transport_template_same_start_v1(uuid,uuid,date,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_update_transport_template_same_start_v1(uuid,uuid,date,jsonb) to service_role;
revoke all on function private.routine_update_transport_template_body_v1(uuid,uuid,date,jsonb) from public,anon,authenticated;
grant execute on function private.routine_update_transport_template_body_v1(uuid,uuid,date,jsonb) to service_role;

alter function public.server_tx_configure_dropoff_pickup(uuid,uuid,jsonb)
  set schema private;
alter function private.server_tx_configure_dropoff_pickup(uuid,uuid,jsonb)
  rename to routine_configure_transport_body_v1;
create function public.server_tx_configure_dropoff_pickup(
  p_actor_id uuid,p_operation_id uuid,p_rows jsonb
) returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  perform 1 from public.task_definitions d
  where d.code in ('dropoff','pickup') and exists(
    select 1 from public.household_members m
    where m.user_id=p_actor_id and m.household_id=d.household_id
  ) order by d.household_id,d.id for no key update of d;
  return private.routine_configure_transport_body_v1(p_actor_id,p_operation_id,p_rows);
end $$;
revoke all on function public.server_tx_configure_dropoff_pickup(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_configure_dropoff_pickup(uuid,uuid,jsonb) to service_role;
revoke all on function private.routine_configure_transport_body_v1(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function private.routine_configure_transport_body_v1(uuid,uuid,jsonb) to service_role;

alter function public.server_tx_configure_evening_routines(uuid,uuid,jsonb)
  set schema private;
alter function private.server_tx_configure_evening_routines(uuid,uuid,jsonb)
  rename to routine_configure_evening_body_v1;
create function public.server_tx_configure_evening_routines(
  p_actor_id uuid,p_operation_id uuid,p_rows jsonb
) returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  perform 1 from public.task_definitions d
  where d.code in ('dinner','bath','laundry','dishes','cleaning','smile_zemi','media_30min') and exists(
    select 1 from public.household_members m
    where m.user_id=p_actor_id and m.household_id=d.household_id
  ) order by d.household_id,d.id for no key update of d;
  return private.routine_configure_evening_body_v1(p_actor_id,p_operation_id,p_rows);
end $$;
revoke all on function public.server_tx_configure_evening_routines(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_configure_evening_routines(uuid,uuid,jsonb) to service_role;
revoke all on function private.routine_configure_evening_body_v1(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function private.routine_configure_evening_body_v1(uuid,uuid,jsonb) to service_role;

alter function private.fn_seed_codmon_daily_for_household_v1(uuid,date)
  rename to routine_seed_codmon_body_v1;
create function private.fn_seed_codmon_daily_for_household_v1(
  p_household_id uuid,p_effective_from date
) returns jsonb language plpgsql security definer set search_path='' as $$
begin
  perform 1 from public.task_definitions d
  where d.household_id=p_household_id and d.code in (
    'codmon_masaki_pickup_input','codmon_shino_previous_input',
    'codmon_shino_breakfast_input','codmon_shino_pickup_input','codmon_submit'
  ) order by d.household_id,d.id for no key update of d;
  return private.routine_seed_codmon_body_v1(p_household_id,p_effective_from);
end $$;
revoke all on function private.fn_seed_codmon_daily_for_household_v1(uuid,date) from public,anon,authenticated;
grant execute on function private.fn_seed_codmon_daily_for_household_v1(uuid,date) to service_role;
revoke all on function private.routine_seed_codmon_body_v1(uuid,date) from public,anon,authenticated;
grant execute on function private.routine_seed_codmon_body_v1(uuid,date) to service_role;

-- The worker intentionally materializes transport first. Snapshot the intended
-- rules and acquire all their definition locks in UUID order before that
-- business order begins, matching bulk schedule replacement. Rules introduced
-- after this snapshot are already materialized by their creating command.
create or replace function public.server_tx_materialize_recurring_batch(p_today date)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  v_rules jsonb; v_rule record; v_household record; v_holiday date;
  v_materialized int:=0; v_failed int:=0;
begin
  if p_today is null then raise exception 'INVALID_INPUT'; end if;
  insert into private.worker_run_receipts(worker_kind,logical_slot_key)
  values('materialize-recurring',p_today::text)
  on conflict(worker_kind,logical_slot_key) do nothing;
  if not found then
    return jsonb_build_object('already_ran',true,'materialized',0,'failed',0);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',rr.id,'household_id',rr.household_id,'task_definition_id',rr.task_definition_id
  ) order by (rr.transport_leg is null),rr.id),'[]'::jsonb) into v_rules
  from public.recurrence_rules rr
  where rr.active and rr.effective_from<=p_today
    and (rr.effective_to is null or rr.effective_to>=p_today);
  perform 1 from public.task_definitions d
  where exists(
    select 1 from jsonb_array_elements(v_rules) r
    where r->>'household_id'=d.household_id::text and r->>'task_definition_id'=d.id::text
  ) order by d.household_id,d.id for no key update of d;

  for v_rule in
    select * from jsonb_to_recordset(v_rules) as r(id uuid,household_id uuid,task_definition_id uuid)
  loop
    begin
      perform private.materialize_recurrence_rule(v_rule.household_id,v_rule.id,p_today,p_today+14);
      v_materialized:=v_materialized+1;
    exception when others then
      v_failed:=v_failed+1;
    end;
  end loop;

  for v_household in select h.id from public.households h loop
    for v_holiday in
      select hd.local_date from private.jp_holidays hd
      where hd.local_date between p_today and p_today+14
        and extract(isodow from hd.local_date)::int<=5
    loop
      begin
        perform private.fn_clear_day_transport_v1(v_household.id,v_holiday,null,null,'holiday','jp_holiday');
      exception when others then
        v_failed:=v_failed+1;
      end;
    end loop;
  end loop;
  update private.worker_run_receipts set completed_at=now(),
    result=jsonb_build_object('materialized',v_materialized,'failed',v_failed)
  where worker_kind='materialize-recurring' and logical_slot_key=p_today::text;
  return jsonb_build_object('already_ran',false,'materialized',v_materialized,'failed',v_failed);
end $$;
revoke all on function public.server_tx_materialize_recurring_batch(date) from public,anon,authenticated;
grant execute on function public.server_tx_materialize_recurring_batch(date) to service_role;

-- The public RPC signatures are unchanged, but moving the old functions gives
-- their wrappers new OIDs. Refresh the API's function cache after commit.
notify pgrst,'reload schema';

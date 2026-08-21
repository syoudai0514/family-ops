-- Week planning read model. Conflict semantics intentionally reuse the canonical
-- private.fn_calendar_conflict_exists predicate used by Today and LINE digests.
create or replace function public.server_tx_get_week_schedule(
  p_actor_id uuid, p_start_date date, p_end_date date
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_household_id uuid; v_connected boolean; v_stale boolean; v_occurrences jsonb; v_assignments jsonb;
begin
  if p_actor_id is null or p_start_date is null or p_end_date is null or p_end_date < p_start_date or p_end_date > p_start_date + 6 then raise exception 'INVALID_INPUT'; end if;
  select household_id into v_household_id from public.household_members where user_id=p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select bool_or(active), bool_or(active and (reauth_required or last_incremental_sync_at is null or last_incremental_sync_at < now()-interval '60 minutes')) into v_connected,v_stale from public.calendar_connections where household_id=v_household_id;
  select coalesce(jsonb_agg(jsonb_build_object('occurrence_key',occ.occurrence_key,'title',occ.title,'starts_at',occ.starts_at,'ends_at',occ.ends_at,'busy_user_ids',(select coalesce(jsonb_agg(bm.user_id),'[]'::jsonb) from public.calendar_occurrence_busy_members bm where bm.household_id=occ.household_id and bm.calendar_connection_id=occ.calendar_connection_id and bm.occurrence_key=occ.occurrence_key)) order by occ.starts_at),'[]'::jsonb) into v_occurrences
  from public.calendar_event_occurrences occ join public.calendar_connections cc on cc.household_id=occ.household_id and cc.id=occ.calendar_connection_id
  where occ.household_id=v_household_id and cc.active and occ.status<>'cancelled' and occ.all_day_start is null and occ.starts_at is not null and coalesce(occ.transparency,'opaque')<>'transparent' and (occ.starts_at at time zone 'Asia/Tokyo')::date between p_start_date and p_end_date;
  select coalesce(jsonb_agg(jsonb_build_object('task_instance_id',ti.id,'title',ti.title,'category',ti.category,'due_at',ti.due_at,'planned_assignee_id',ti.planned_assignee_id,'has_conflict',private.fn_calendar_conflict_exists(ti.household_id,ti.planned_assignee_id,ti.due_at,coalesce(rr.conflict_window_minutes,60))) order by ti.due_at),'[]'::jsonb) into v_assignments
  from public.task_instances ti left join public.recurrence_rules rr on rr.household_id=ti.household_id and rr.id=ti.recurrence_rule_id
  where ti.household_id=v_household_id and ti.scheduled_date between p_start_date and p_end_date and ti.status in ('todo','in_progress') and ti.due_at is not null and ti.planned_assignee_id is not null;
  return jsonb_build_object('household_id',v_household_id,'start_date',p_start_date,'end_date',p_end_date,'calendar_connected',coalesce(v_connected,false),'calendar_stale',coalesce(v_stale,false),'occurrences',v_occurrences,'assignments',v_assignments);
end $$;
revoke all on function public.server_tx_get_week_schedule(uuid,date,date) from public,anon,authenticated;
grant execute on function public.server_tx_get_week_schedule(uuid,date,date) to service_role;

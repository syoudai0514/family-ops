-- Lane D CF-02 / CF-04.
-- `server_tx_get_today_schedule` is the historical RPC consumed by the LINE
-- worker for the literal 「今日」 entry. Preserve the former schedule reader
-- for compatibility callers, then turn the historical LINE RPC name into a
-- presentation adapter over the canonical DailyBrief. No business semantics
-- are recomputed here.

alter function public.server_tx_get_today_schedule(uuid)
  rename to server_read_today_schedule_legacy_v1;

revoke all on function public.server_read_today_schedule_legacy_v1(uuid)
  from public, anon, authenticated;
grant execute on function public.server_read_today_schedule_legacy_v1(uuid)
  to service_role;

create or replace function public.server_tx_get_today_schedule(
  p_actor_id uuid
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_date date := (now() at time zone 'Asia/Tokyo')::date;
  v_text text;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;

  select hm.household_id into v_household_id
  from public.household_members hm
  where hm.user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  -- The existing LINE worker expects {assignments, occurrences}. Feed that
  -- transport one synthetic presentation row whose text is rendered from the
  -- same DailyBrief used by PWA Today and scheduled morning/evening briefs.
  v_text := public.server_render_daily_brief_text(p_actor_id, v_date);

  return jsonb_build_object(
    'household_id', v_household_id,
    'local_date', v_date,
    'calendar_connected', true,
    'calendar_stale', false,
    'assignments', jsonb_build_array(jsonb_build_object(
      'task_instance_id', null,
      'title', v_text,
      'category', 'daily_brief',
      'due_at', null,
      'planned_assignee_id', null,
      'has_conflict', false
    )),
    'occurrences', '[]'::jsonb,
    'reader_state', 'daily_brief_adapter_v1'
  );
end;
$$;

revoke all on function public.server_tx_get_today_schedule(uuid)
  from public, anon, authenticated;
grant execute on function public.server_tx_get_today_schedule(uuid)
  to service_role;

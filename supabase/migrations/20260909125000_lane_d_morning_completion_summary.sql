-- Lane D Q87 / CF-02 follow-up.
-- Keep the evening "朝 n/n 完了" summary server-owned by deriving it from
-- the canonical DailyBrief projection. React must not reclassify task rows.

create or replace function private.fn_daily_brief_morning_summary_v1(
  p_brief jsonb
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_completed integer := 0;
  v_remaining integer := jsonb_array_length(
    coalesce(p_brief->'own_task_groups'->'morning', '[]'::jsonb)
  );
begin
  select count(*)::integer
    into v_completed
  from jsonb_array_elements(coalesce(p_brief->'already_handled', '[]'::jsonb)) item
  join public.task_instances t
    on t.id = nullif(item->>'task_id', '')::uuid
  where t.routine_phase = 'morning';

  return jsonb_build_object(
    'completed_count', v_completed,
    'total_count', v_completed + v_remaining
  );
end;
$$;

revoke all on function private.fn_daily_brief_morning_summary_v1(jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_daily_brief_morning_summary_v1(jsonb)
  to service_role;

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
  v_base jsonb;
  v_brief jsonb;
begin
  v_base := public.server_read_daily_brief_base_v1(p_actor_id, p_local_date);
  v_brief := private.fn_enrich_daily_brief_v2(p_actor_id, p_local_date, v_base);

  return v_brief || jsonb_build_object(
    'morning_summary', private.fn_daily_brief_morning_summary_v1(v_brief)
  );
end;
$$;

revoke all on function public.server_read_daily_brief(uuid, date)
  from public, anon, authenticated;
grant execute on function public.server_read_daily_brief(uuid, date)
  to service_role;

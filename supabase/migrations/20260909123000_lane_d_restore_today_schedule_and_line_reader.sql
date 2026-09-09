-- Lane D CF-02 / CF-04.
-- Dedicated presentation-only reader for LINE `今日`.
-- The established detailed schedule RPC is deliberately untouched; LINE Today
-- reads the same canonical DailyBrief renderer used by the PWA/daily briefs.

create or replace function public.server_read_line_today_daily_brief(
  p_actor_id uuid
) returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_date date := (now() at time zone 'Asia/Tokyo')::date;
begin
  if p_actor_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  -- Authorization and household membership are enforced by the canonical
  -- DailyBrief reader reached by this renderer.
  return public.server_render_daily_brief_text(p_actor_id, v_date);
end;
$$;

revoke all on function public.server_read_line_today_daily_brief(uuid)
  from public, anon, authenticated;
grant execute on function public.server_read_line_today_daily_brief(uuid)
  to service_role;

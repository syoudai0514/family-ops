-- #233: an absent record is not evidence that the morning work was missed.
-- Preserve the existing renderer for all other sections and modes; queued
-- daily notes use the same function when their outbox entry is claimed.
alter function private.fn_render_daily_brief_text_v4(jsonb,text) rename to fn_render_daily_brief_before_evening_calm_v1;
revoke all on function private.fn_render_daily_brief_before_evening_calm_v1(jsonb,text) from public,anon,authenticated;
grant execute on function private.fn_render_daily_brief_before_evening_calm_v1(jsonb,text) to service_role;

create function private.fn_render_daily_brief_text_v4(p_brief jsonb,p_mode text)
returns text language plpgsql immutable security invoker set search_path='' as $$
declare filtered jsonb:=p_brief; body text;
begin
  if p_mode='evening' and jsonb_typeof(filtered->'own_task_groups')='object' then
    filtered:=jsonb_set(filtered,'{own_task_groups,morning}','[]'::jsonb,true);
    filtered:=jsonb_set(filtered,'{own_task_groups,daytime}','[]'::jsonb,true);
  end if;
  body:=private.fn_render_daily_brief_before_evening_calm_v1(filtered,p_mode);
  return replace(body,E'\n\n⭐ 今日、忘れずに\n',E'\n\n⭐ 今日だけの予定\n');
end $$;
revoke all on function private.fn_render_daily_brief_text_v4(jsonb,text) from public,anon,authenticated;
grant execute on function private.fn_render_daily_brief_text_v4(jsonb,text) to service_role;

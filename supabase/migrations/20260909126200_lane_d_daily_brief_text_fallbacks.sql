-- Lane D CF-02 / CF-04 presentation hardening.
-- DailyBrief refs are canonical but different semantic kinds use different
-- human-readable fields. Keep one common text-line helper so LINE/digests do
-- not degrade request, exception or waiting items to a generic "項目" label.

create or replace function private.fn_daily_brief_lines_v1(p_items jsonb)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select string_agg(
    '・' || coalesce(
      nullif(item->>'title', ''),
      nullif(item->>'shared_title', ''),
      nullif(item->>'shared_text', ''),
      nullif(item->>'message', ''),
      nullif(item->>'detail', ''),
      nullif(item->>'waiting_note', ''),
      nullif(item->>'name', ''),
      '確認が必要な項目'
    ),
    E'\n'
  )
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) item
$$;

revoke all on function private.fn_daily_brief_lines_v1(jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_daily_brief_lines_v1(jsonb)
  to service_role;

-- F2 actual LINE verification found a real-use ambiguity: separate recurring
-- task instances can share the same title while having distinct due times.
-- The canonical DailyBrief keeps those due_at values, but the text renderer
-- previously emitted title only, making morning/evening occurrences look like
-- accidental duplicates in LINE.
--
-- Preserve the compact normal case. Only when the same human-readable label
-- appears more than once in the same rendered section, prefix an available
-- due_at/starts_at with its JST HH:MM value so the occurrences are visibly
-- distinguishable. Q67 requires all own tasks to remain readable in LINE.

create or replace function private.fn_daily_brief_lines_v1(p_items jsonb)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  with normalized as (
    select
      item,
      ord,
      coalesce(
        nullif(item->>'title', ''),
        nullif(item->>'shared_title', ''),
        nullif(item->>'shared_text', ''),
        nullif(item->>'message', ''),
        nullif(item->>'detail', ''),
        nullif(item->>'waiting_note', ''),
        nullif(item->>'name', ''),
        '確認が必要な項目'
      ) as label,
      coalesce(
        nullif(item->>'due_at', ''),
        nullif(item->>'starts_at', '')
      ) as occurrence_at
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
      with ordinality as entries(item, ord)
  ), annotated as (
    select
      normalized.*,
      count(*) over (partition by label) as same_label_count
    from normalized
  )
  select string_agg(
    '・'
    || case
      when same_label_count > 1 and occurrence_at is not null then
        to_char(
          occurrence_at::timestamptz at time zone 'Asia/Tokyo',
          'HH24:MI'
        ) || ' '
      else ''
    end
    || label,
    E'\n' order by ord
  )
  from annotated
$$;

revoke all on function private.fn_daily_brief_lines_v1(jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_daily_brief_lines_v1(jsonb)
  to service_role;

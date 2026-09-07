-- Production hotfix: daily brief rendering must extract JSON text before
-- concatenating the Japanese bullet prefix. Without the parentheses PostgreSQL
-- can bind the generic operators as ('・' || x) ->> 'title', which attempts to
-- treat the bullet text as JSON and raises `invalid input syntax for type json`.
--
-- Keep the formatter contract otherwise identical: same sections, order,
-- separators, immutability, search_path and 5000-character cap.
create or replace function private.fn_render_daily_brief_text_v1(p_brief jsonb)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_text text := '今日のおうちノート';
  v_part text;
begin
  select string_agg('・' || (x->>'title'), E'\n')
    into v_part
  from jsonb_array_elements(coalesce(p_brief->'urgent_actions', '[]'::jsonb)) x;

  if v_part is not null then
    v_text := v_text || E'\n\nまず確認\n' || v_part;
  end if;

  select string_agg('・' || (x->>'title'), E'\n')
    into v_part
  from jsonb_array_elements(coalesce(p_brief->'tasks', '[]'::jsonb)) x;

  if v_part is not null then
    v_text := v_text || E'\n\n今日やること\n' || v_part;
  end if;

  select string_agg('・' || (x->>'title'), E'\n')
    into v_part
  from jsonb_array_elements(coalesce(p_brief->'shopping', '[]'::jsonb)) x;

  if v_part is not null then
    v_text := v_text || E'\n\n買い物\n' || v_part;
  end if;

  return left(v_text, 5000);
end;
$$;

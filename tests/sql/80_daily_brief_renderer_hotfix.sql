-- Regression for the production 2026-09-07 morning DailyBrief outage.
-- The pre-fix formatter throws `invalid input syntax for type json` because
-- `'・'||x->>'title'` can bind as JSON extraction from the concatenated
-- expression. PostgreSQL then tries to coerce the bullet literal to JSON during
-- expression evaluation, so the formatter can fail even before any actual title
-- row is needed. This test must therefore fail against the old formatter and
-- pass only when extraction is parenthesized before text concatenation.
\set ON_ERROR_STOP on

do $$
declare
  v_rendered text;
  v_expected text := E'今日のおうちノート\n\nまず確認\n・期限確認\n\n今日やること\n・ゴミ出し\n\n買い物\n・牛乳';
begin
  v_rendered := private.fn_render_daily_brief_text_v1(
    jsonb_build_object(
      'urgent_actions', jsonb_build_array(jsonb_build_object('title', '期限確認')),
      'tasks', jsonb_build_array(jsonb_build_object('title', 'ゴミ出し')),
      'shopping', jsonb_build_array(jsonb_build_object('title', '牛乳'))
    )
  );

  if v_rendered <> v_expected then
    raise exception 'FAIL daily-brief-renderer: unexpected output: %', v_rendered;
  end if;

  if private.fn_render_daily_brief_text_v1('{}'::jsonb) <> '今日のおうちノート' then
    raise exception 'FAIL daily-brief-renderer: empty brief contract changed';
  end if;
end;
$$;

select 'daily_brief_renderer_hotfix: PASS' as result;

-- F2 regression: same-title recurring occurrences must remain distinguishable
-- in LINE while unique labels stay compact.
\set ON_ERROR_STOP on

begin;
set local role service_role;

do $$
declare
  v_lines text;
begin
  v_lines := private.fn_daily_brief_lines_v1(
    jsonb_build_array(
      jsonb_build_object(
        'title', '同名タスク',
        'due_at', '2026-09-09T22:00:00+00:00'
      ),
      jsonb_build_object(
        'title', '同名タスク',
        'due_at', '2026-09-10T11:45:00+00:00'
      ),
      jsonb_build_object(
        'title', '一回だけ',
        'due_at', '2026-09-10T09:00:00+00:00'
      )
    )
  );

  if position('・07:00 同名タスク' in v_lines) = 0
     or position('・20:45 同名タスク' in v_lines) = 0 then
    raise exception 'FAIL f2-line-duplicate-time-labels: duplicate occurrences are not distinguishable: %', v_lines;
  end if;

  if position('・一回だけ' in v_lines) = 0
     or position('・18:00 一回だけ' in v_lines) > 0 then
    raise exception 'FAIL f2-line-duplicate-time-labels: unique title should remain compact: %', v_lines;
  end if;

  if position('・07:00 同名タスク' in v_lines) > position('・20:45 同名タスク' in v_lines) then
    raise exception 'FAIL f2-line-duplicate-time-labels: source order changed: %', v_lines;
  end if;
end;
$$;

rollback;
select 'f2_line_daily_brief_duplicate_time_labels: PASS' as result;

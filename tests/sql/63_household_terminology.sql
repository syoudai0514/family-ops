-- Q72: terminology is confirmed explicitly, household-scoped, editable and
-- deletable. It has no assignment or routine columns, so learning language
-- cannot mutate those rules as a side effect.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('54000000-0000-0000-0000-000000000001'),
  ('54000000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_first jsonb;
  v_second jsonb;
  v_first_household uuid;
  v_term_id uuid;
  v_column_count integer;
begin
  v_first := public.server_tx_create_household(
    '54000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Terminology A', 'Owner A'
  );
  v_first_household := (v_first->>'household_id')::uuid;
  v_second := public.server_tx_create_household(
    '54000000-0000-0000-0000-000000000002', gen_random_uuid(), 'Terminology B', 'Owner B'
  );

  perform public.server_tx_replace_household_terminology(
    '54000000-0000-0000-0000-000000000001', gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('phrase','送り','meaning','保育園の送り'))
  );
  select id into v_term_id from public.household_terminology
    where household_id = v_first_household and phrase = '送り';
  if v_term_id is null then raise exception 'FAIL terminology: confirmed term was not saved'; end if;

  -- Edit is an explicit reconfirmation; deletion happens only when the user
  -- saves a reviewed list without that row.
  perform public.server_tx_replace_household_terminology(
    '54000000-0000-0000-0000-000000000001', gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('id',v_term_id,'phrase','送り','meaning','保育園へ送る'))
  );
  if (select meaning from public.household_terminology where id = v_term_id) <> '保育園へ送る' then
    raise exception 'FAIL terminology: edit did not persist';
  end if;
  perform public.server_tx_replace_household_terminology(
    '54000000-0000-0000-0000-000000000001', gen_random_uuid(), '[]'::jsonb
  );
  if exists (select 1 from public.household_terminology where id = v_term_id) then
    raise exception 'FAIL terminology: deleted term remains active';
  end if;

  begin
    perform public.server_tx_replace_household_terminology(
      '54000000-0000-0000-0000-000000000002', gen_random_uuid(),
      jsonb_build_array(jsonb_build_object('id',v_term_id,'phrase','送り','meaning','別家庭'))
    );
    raise exception 'FAIL terminology: another household may edit a removed foreign term';
  exception when others then
    if sqlerrm <> 'INVALID_INPUT' then raise; end if;
  end;

  select count(*) into v_column_count from information_schema.columns
    where table_schema = 'public' and table_name = 'household_terminology'
      and column_name in ('assignee_user_id','planned_assignee_user_id','weekday','routine_id');
  if v_column_count <> 0 then raise exception 'FAIL terminology: language table must not contain assignment/routine rule fields'; end if;
end;
$$;

reset role;
select 'household_terminology: PASS' as result;

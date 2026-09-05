-- Q17 literal: template + AI candidate + human confirmation.
-- Proposal must not mutate canonical Event/Todo state; confirmation writes
-- exactly the user-reviewed subset, with per-Todo assignment state.
\set ON_ERROR_STOP on

insert into auth.users(id) values ('a6000000-0000-0000-0000-000000000001');
set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_draft jsonb;
  v_draft_id uuid;
  v_confirm jsonb;
  v_event_id uuid;
  v_event_count int;
  v_task_count int;
  v_ai_count int;
  v_unassigned_count int;
  v_person_count int;
begin
  v_hh := public.server_tx_create_household(
    'a6000000-0000-0000-0000-000000000001',gen_random_uuid(),'Q17 HH','Owner'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;

  select count(*) into v_event_count from public.family_events where household_id=v_hh_id;
  select count(*) into v_task_count from public.task_instances where household_id=v_hh_id;
  if v_event_count <> 0 or v_task_count <> 0 then raise exception 'FAIL q17: fixture not empty'; end if;

  v_draft := public.server_tx_begin_event_planning_draft(
    'a6000000-0000-0000-0000-000000000001',gen_random_uuid(),'ceremony',
    jsonb_build_object('title','七五三','event_date','2026-11-22','details','祖父母も参加','location','伊勢山皇大神宮'),
    jsonb_build_array(
      jsonb_build_object('candidate_id','template-ceremony-1','source','template','title','服装・持ち物を確認する','scheduled_date','2026-11-15')
    ),
    jsonb_build_array(
      jsonb_build_object('candidate_id','ai-1','source','ai','title','祖父母へ集合時間を共有する','scheduled_date','2026-11-19','reason','家族調整'),
      jsonb_build_object('candidate_id','ai-2','source','ai','title','昼食予約を確認する','scheduled_date','2026-11-08','reason','当日の移動を滑らかにする')
    )
  );
  v_draft_id := (v_draft->>'draft_id')::uuid;

  -- Candidate creation is review-only: absolutely no canonical mutation.
  if (select count(*) from public.family_events where household_id=v_hh_id) <> 0
     or (select count(*) from public.task_instances where household_id=v_hh_id) <> 0 then
    raise exception 'FAIL q17: proposal mutated canonical Event/Todo before human confirmation';
  end if;
  if jsonb_array_length(v_draft->'template_candidates') <> 1
     or jsonb_array_length(v_draft->'ai_candidates') <> 2 then
    raise exception 'FAIL q17: template and AI candidate sets not retained separately';
  end if;

  -- Human keeps one template item + one AI item and deliberately omits ai-2.
  -- The selected titles/dates are the reviewed values, not blindly copied AI.
  v_confirm := public.server_tx_confirm_event_planning_draft(
    'a6000000-0000-0000-0000-000000000001',gen_random_uuid(),v_draft_id,
    (v_draft->>'revision')::bigint,
    jsonb_build_object('title','七五三（伊勢山）','event_date','2026-11-22','details','祖父母も参加','location','伊勢山皇大神宮'),
    jsonb_build_array(
      jsonb_build_object('candidate_id','template-ceremony-1','title','着物と子どもの持ち物を確認','scheduled_date','2026-11-15','planned_assignee_user_id','a6000000-0000-0000-0000-000000000001'),
      jsonb_build_object('candidate_id','ai-1','title','祖父母へ13時集合を共有','scheduled_date','2026-11-19')
    )
  );
  v_event_id := (v_confirm->>'family_event_id')::uuid;
  if v_confirm->>'status' <> 'confirmed' or (v_confirm->>'task_count')::int <> 2 then
    raise exception 'FAIL q17: confirmation result does not reflect selected subset';
  end if;

  select count(*) into v_event_count from public.family_events
    where household_id=v_hh_id and id=v_event_id and title='七五三（伊勢山）' and starts_on='2026-11-22';
  if v_event_count <> 1 then raise exception 'FAIL q17: reviewed canonical Event missing'; end if;

  select count(*) into v_task_count from public.task_instances
    where household_id=v_hh_id and event_id=v_event_id;
  select count(*) into v_ai_count from public.task_instances
    where household_id=v_hh_id and event_id=v_event_id
      and source_context->>'candidate_source'='ai';
  if v_task_count <> 2 or v_ai_count <> 1 then
    raise exception 'FAIL q17: unselected AI candidate was auto-confirmed';
  end if;
  if exists(select 1 from public.task_instances where household_id=v_hh_id and event_id=v_event_id and title='昼食予約を確認する') then
    raise exception 'FAIL q17: omitted AI candidate became canonical Todo';
  end if;
  if not exists(select 1 from public.task_instances where household_id=v_hh_id and event_id=v_event_id and title='祖父母へ13時集合を共有') then
    raise exception 'FAIL q17: human-edited AI candidate value was not used';
  end if;

  select count(*) into v_unassigned_count from public.task_instances
    where household_id=v_hh_id and event_id=v_event_id and assignment_mode='unassigned';
  select count(*) into v_person_count from public.task_instances
    where household_id=v_hh_id and event_id=v_event_id and assignment_mode='person';
  if v_unassigned_count <> 1 or v_person_count <> 1 then
    raise exception 'FAIL q17/q18: per-Todo assignment state not preserved';
  end if;
  if exists(select 1 from information_schema.columns
    where table_schema='public' and table_name='family_events'
      and column_name in ('coordinator_user_id','owner_user_id','manager_user_id')) then
    raise exception 'FAIL q18: Event gained a prohibited overall coordinator';
  end if;

  -- Terminal draft is not revivable through a second independent confirm.
  begin
    perform public.server_tx_confirm_event_planning_draft(
      'a6000000-0000-0000-0000-000000000001',gen_random_uuid(),v_draft_id,
      (v_draft->>'revision')::bigint,
      jsonb_build_object('title','再確定','event_date','2026-11-22'),'[]'::jsonb
    );
    raise exception 'FAIL q17: confirmed draft was confirmed again';
  exception when others then
    if sqlerrm <> 'EVENT_DRAFT_NOT_EDITABLE' then raise; end if;
  end;
end;
$$;

reset role;
select 'q17_event_planning_confirmation: PASS' as result;

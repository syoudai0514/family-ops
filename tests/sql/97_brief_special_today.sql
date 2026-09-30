-- Owner decision 2026-09-30: the scheduled LINE brief has a "⭐ 今日だけ" block
-- holding tasks that do NOT happen every weekday. A task qualifies when its
-- definition has active rules on fewer than all five weekdays that day, or no
-- rule at all. Daily routines (Mon-Fri, or all 7 days) do not.
\set ON_ERROR_STOP on

begin;
set role service_role;

do $$
declare
  u1 uuid:=gen_random_uuid();
  hh uuid;
  day date:=date '2026-10-07'; -- a Wednesday
  daily_def uuid;
  daily7_def uuid;
  wed_def uuid;
  daily_t uuid;
  daily7_t uuid;
  wed_t uuid;
  manual_t uuid;
  d int;
  brief jsonb;
  split jsonb;
  line jsonb;
  text_morning text;
  text_evening text;
begin
  if extract(isodow from day)::int <> 3 then raise exception 'fixture day must be a Wednesday'; end if;
  insert into auth.users(id) values(u1);
  hh:=(public.server_tx_create_household(u1,gen_random_uuid(),'special today','Owner')->>'household_id')::uuid;

  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by,task_kind)
  values(hh,'sp_daily','朝ごはん','household','morning','whole',u1,'daily_routine') returning id into daily_def;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by,task_kind)
  values(hh,'sp_daily7','スマイルゼミ','learning','evening','whole',u1,'daily_routine') returning id into daily7_def;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by,task_kind)
  values(hh,'sp_wed','プラゴミのゴミ出し','garbage','morning','whole',u1,'daily_routine') returning id into wed_def;

  for d in 1..5 loop
    insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,scheduled_local_time,effective_from,active,created_by)
    values(hh,daily_def,d,'sp-daily-'||d,'fixed',u1,time '07:00',day-30,true,u1);
  end loop;
  for d in 1..7 loop
    insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,scheduled_local_time,effective_from,active,created_by)
    values(hh,daily7_def,d,'sp-daily7-'||d,'fixed',u1,time '19:00',day-30,true,u1);
  end loop;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,scheduled_local_time,effective_from,active,created_by)
  values(hh,wed_def,3,'sp-wed','fixed',u1,time '07:30',day-30,true,u1);

  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,due_at,planned_assignee_id,assignment_mode,assignment_source,completion_mode,status,source,created_by)
  values(hh,daily_def,'recurring','朝ごはん','household','morning',day,((day::text||' 07:00')::timestamp at time zone 'Asia/Tokyo'),u1,'person','legacy_snapshot','whole','todo','test',u1)
  returning id into daily_t;
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,due_at,planned_assignee_id,assignment_mode,assignment_source,completion_mode,status,source,created_by)
  values(hh,daily7_def,'recurring','スマイルゼミ','learning','evening',day,((day::text||' 19:00')::timestamp at time zone 'Asia/Tokyo'),u1,'person','legacy_snapshot','whole','todo','test',u1)
  returning id into daily7_t;
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,due_at,planned_assignee_id,assignment_mode,assignment_source,completion_mode,status,source,created_by)
  values(hh,wed_def,'recurring','プラゴミのゴミ出し','garbage','morning',day,((day::text||' 07:30')::timestamp at time zone 'Asia/Tokyo'),u1,'person','legacy_snapshot','whole','todo','test',u1)
  returning id into wed_t;
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,due_at,planned_assignee_id,assignment_mode,assignment_source,completion_mode,status,source,created_by)
  values(hh,null,'manual','食育の準備（すだちぐみ 食育）','todo','morning',day,null,u1,'person','legacy_snapshot','whole','todo','test',u1)
  returning id into manual_t;

  brief:=jsonb_build_object(
    'own_task_groups', jsonb_build_object(
      'morning', jsonb_build_array(
        jsonb_build_object('task_id',daily_t,'title','朝ごはん','category','household'),
        jsonb_build_object('task_id',wed_t,'title','プラゴミのゴミ出し','category','garbage'),
        jsonb_build_object('task_id',manual_t,'title','食育の準備（すだちぐみ 食育）','category','todo')),
      'daytime', '[]'::jsonb,
      'evening', jsonb_build_array(jsonb_build_object('task_id',daily7_t,'title','スマイルゼミ','category','learning')),
      'optional', '[]'::jsonb),
    'partner_summary', '{}'::jsonb);

  split:=private.fn_brief_split_special_v1(brief);
  -- Only what does not happen every weekday is special: the Wednesday-only task
  -- and the manual one. Mon-Fri and 7-day routines are not.
  if (select array_agg(x->>'title' order by x->>'title') from jsonb_array_elements(split->'special_today') x)
     is distinct from array['プラゴミのゴミ出し','食育の準備（すだちぐみ 食育）'] then
    raise exception 'special_today wrong: %', split->'special_today';
  end if;
  -- Shown once: removed from the daypart groups, daily routines stay.
  if split#>'{own_task_groups,morning}' is distinct from jsonb_build_array(jsonb_build_object('task_id',daily_t,'title','朝ごはん','category','household')) then
    raise exception 'morning group wrong: %', split#>'{own_task_groups,morning}';
  end if;
  if jsonb_array_length(split#>'{own_task_groups,evening}') <> 1 then
    raise exception 'evening group changed';
  end if;

  -- A Saturday-only... no: a rule on only some weekdays is special too.
  delete from public.recurrence_rules where task_definition_id=daily_def and weekday=5;
  split:=private.fn_brief_split_special_v1(brief);
  if not (split->'special_today' @> jsonb_build_array(jsonb_build_object('task_id',daily_t,'title','朝ごはん','category','household'))) then
    raise exception 'a task missing one weekday should become special';
  end if;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,scheduled_local_time,effective_from,active,created_by)
  values(hh,daily_def,5,'sp-daily-5b','fixed',u1,time '07:00',day-30,true,u1);

  -- The scheduled brief carries the block; the renderer prints it right after まず確認.
  line:=private.fn_daily_brief_for_line_v1(brief, u1, (day::text||' 07:00')::timestamp at time zone 'Asia/Tokyo', 'morning');
  text_morning:=private.fn_render_daily_brief_text_v3(line,'morning');
  if position(E'⭐ 今日だけ（いつもと違う）\n・プラゴミのゴミ出し\n・食育の準備（すだちぐみ 食育）' in text_morning)=0 then
    raise exception 'morning brief lacks the special block: %', text_morning;
  end if;
  if text_morning !~ E'朝やること\n・朝ごはん\n?$' and text_morning !~ E'朝やること\n・朝ごはん' then
    raise exception 'daily routine should stay under 朝やること: %', text_morning;
  end if;
  if position('・プラゴミのゴミ出し' in substring(text_morning from position('朝やること' in text_morning)))>0 then
    raise exception 'special task must not be repeated in its daypart group';
  end if;

  line:=private.fn_daily_brief_for_line_v1(brief, u1, (day::text||' 20:30')::timestamp at time zone 'Asia/Tokyo', 'evening');
  text_evening:=private.fn_render_daily_brief_text_v3(line,'evening');
  if position('⭐ 今日だけ' in text_evening)=0 then raise exception 'evening brief lacks the special block: %', text_evening; end if;

  -- No special tasks -> no block (a brief without task ids, like older fixtures, is unchanged).
  line:=private.fn_daily_brief_for_line_v1('{"own_task_groups":{"morning":[{"title":"朝の片付け","category":"household"}]}}'::jsonb, u1, (day::text||' 07:00')::timestamp at time zone 'Asia/Tokyo','morning');
  if position('⭐' in private.fn_render_daily_brief_text_v3(line,'morning'))>0 then
    raise exception 'a brief with nothing special must not print the block';
  end if;
end $$;

rollback;

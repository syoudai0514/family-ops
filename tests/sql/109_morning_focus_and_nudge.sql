\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); h uuid; token text;
  chore_def uuid; codmon_def uuid; day date := date '2027-02-02';  -- Tuesday
  at_0730 timestamptz := timestamptz '2027-02-02 07:30:00+09';
  n int; body1 text; body2 text; focus text; whole_text text; brief jsonb; result jsonb;
begin
  insert into auth.users(id) values(u1),(u2);
  insert into public.profiles(user_id,display_name) values(u1,'Nudge Papa'),(u2,'Nudge Mama');
  h := (public.server_tx_create_household(u1,gen_random_uuid(),'Nudge H','Papa')->>'household_id')::uuid;
  token := public.server_tx_create_household_invite(u1,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(u2,gen_random_uuid(),token,'Mama');
  update public.notification_preferences set daily_assignment_line=true where household_id=h;

  if (select morning_nudge_local_time from public.households where id=h)<>time '07:30' then raise exception 'FAIL default nudge time'; end if;

  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,created_by)
  values(h,'nudge_chore','朝のしごと','household','morning','whole','hidden','morning_chore',u1) returning id into chore_def;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,created_by)
  values(h,'codmon_nudge_input','詩乃：コドモン入力（朝食）','nursery','morning','whole','hidden','morning_chore',u1) returning id into codmon_def;

  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,completion_mode,status,source,created_by,planned_assignee_id,assignment_mode,expectation,due_at)
  values
   (h,chore_def,'manual','朝ごはん','household','morning',day,'whole','todo','test',u1,u1,'person','normal',timestamptz '2027-02-02 07:00:00+09'),
   (h,chore_def,'manual','洗濯物を干す','household','morning',day,'whole','todo','test',u1,u1,'person','normal',timestamptz '2027-02-02 07:10:00+09'),
   (h,chore_def,'manual','将生：体操着に着替える','household','morning',day,'whole','todo','test',u1,u2,'person','normal',timestamptz '2027-02-02 07:20:00+09'),
   (h,chore_def,'manual','食洗機を空ける（先に家を出る人）','household','morning',day,'whole','todo','test',u1,null,'anyone','normal',timestamptz '2027-02-02 07:00:00+09'),
   (h,codmon_def,'manual','詩乃：コドモン入力（朝食）','nursery','morning',day,'whole','todo','test',u1,u1,'person','normal',timestamptz '2027-02-02 09:15:00+09'),
   (h,chore_def,'manual','お風呂','household','evening',day,'whole','todo','test',u1,u1,'person','normal',timestamptz '2027-02-02 20:00:00+09'),
   (h,chore_def,'manual','窓拭き','household','morning',day,'whole','todo','test',u1,u1,'person','optional',null);

  perform public.server_tx_complete_task(u1,gen_random_uuid(),
    (select id from public.task_instances where household_id=h and title='洗濯物を干す'),'self',false,'pwa');

  -- Nothing before the time, and nothing on a weekend.
  if public.server_tx_dispatch_morning_nudges(at_0730 - interval '31 minutes')<>0 then raise exception 'FAIL nudge before its time'; end if;
  if public.server_tx_dispatch_morning_nudges(timestamptz '2027-02-07 07:30:00+09')<>0 then raise exception 'FAIL nudge on a Sunday'; end if;

  n := public.server_tx_dispatch_morning_nudges(at_0730);
  if n<>2 then raise exception 'FAIL expected 2 nudges, got %', n; end if;
  select body into body1 from public.user_notifications where recipient_user_id=u1 and type='morning_nudge';
  select body into body2 from public.user_notifications where recipient_user_id=u2 and type='morning_nudge';
  if body1 not like E'%07:00 朝ごはん\n・07:00 食洗機を空ける（先に家を出る人）%' or body1 like '%体操着%' or body1 like '%洗濯物%'
     or body1 like '%コドモン%' or body1 like '%お風呂%' or body1 like '%窓拭き%' then
    raise exception 'FAIL papa nudge: %', body1; end if;
  if body2 not like '%07:20 将生：体操着に着替える%' or body2 not like '%食洗機を空ける%' or body2 like '%朝ごはん%' then
    raise exception 'FAIL mama nudge: %', body2; end if;
  if (select count(*) from private.notification_outbox where household_id=h and type='morning_nudge' and channel='line')<>2 then
    raise exception 'FAIL expected a LINE message each'; end if;

  -- One message a day, even when the worker runs again inside the window.
  if public.server_tx_dispatch_morning_nudges(at_0730 + interval '10 minutes')<>0 then raise exception 'FAIL nudge sent twice'; end if;

  -- Everything done: nothing is sent.
  update public.task_instances set status='cancelled' where household_id=h and status='todo' and routine_phase='morning';
  update public.task_instances set scheduled_date=day+1, due_at=due_at+interval '1 day' where household_id=h and scheduled_date=day;
  if public.server_tx_dispatch_morning_nudges(at_0730 + interval '1 day')<>0 then raise exception 'FAIL nudge with nothing left'; end if;

  -- The time is a household setting; 'off' sends nothing.
  perform public.server_tx_update_reminder_settings(u1,gen_random_uuid(),'{"morning_nudge_local_time":"08:00"}');
  if (select morning_nudge_local_time from public.households where id=h)<>time '08:00' then raise exception 'FAIL set nudge time'; end if;
  begin perform public.server_tx_update_reminder_settings(u1,gen_random_uuid(),'{"morning_nudge_local_time":"12:00"}'); raise exception 'FAIL noon accepted';
  exception when others then if sqlerrm<>'INVALID_INPUT' then raise; end if; end;
  begin perform public.server_tx_update_reminder_settings(u1,gen_random_uuid(),'{"morning_nudge_local_time":"7:30pm"}'); raise exception 'FAIL junk accepted';
  exception when others then if sqlerrm<>'INVALID_INPUT' then raise; end if; end;
  perform public.server_tx_update_reminder_settings(u1,gen_random_uuid(),'{"morning_nudge_local_time":null}');
  if (select morning_nudge_local_time from public.households where id=h) is not null then raise exception 'FAIL nudge off'; end if;

  -- Layout: the scheduled morning note leads with the morning, the 今日 reply stays full.
  brief := jsonb_build_object('display_recipient_user_id',u1,
    'own_task_groups',jsonb_build_object(
      'morning',jsonb_build_array(
        jsonb_build_object('task_id',gen_random_uuid(),'display_title','朝ごはん','due_at','2027-02-01T22:00:00+00:00','assignment_mode','person'),
        jsonb_build_object('task_id',gen_random_uuid(),'display_title','将生：コドモン入力','due_at','2027-02-02T00:15:00+00:00','assignment_mode','person'),
        jsonb_build_object('task_id',gen_random_uuid(),'display_title','食洗機を空ける','due_at','2027-02-01T22:00:00+00:00','assignment_mode','anyone','responsibility_hint','先に家を出る人'),
        jsonb_build_object('task_id',gen_random_uuid(),'display_title','燃えるゴミを出す','due_at','2027-02-01T22:30:00+00:00','assignment_mode','person')),
      'daytime','[]'::jsonb,
      'evening',jsonb_build_array(
        jsonb_build_object('display_title','お風呂','assignment_mode','person'),
        jsonb_build_object('display_title','食器洗い','assignment_mode','person'),
        jsonb_build_object('display_title','洗濯','assignment_mode','person')),
      'optional',jsonb_build_array(jsonb_build_object('display_title','窓拭き','assignment_mode','anyone','expectation','optional'))),
    'tomorrow_impact',jsonb_build_object('local_date','2027-02-03','tasks',jsonb_build_array(
      jsonb_build_object('display_title','英語教材の準備','due_at','2027-02-02T12:00:00+00:00'))));
  focus := private.fn_render_daily_brief_text_v4(brief,'morning_focus');
  whole_text := private.fn_render_daily_brief_text_v4(brief,'morning');
  if focus not like E'%⏰ 朝やること（時刻順）\n・07:00 朝ごはん\n・07:00 食洗機を空ける（先に家を出る人）\n・07:30 燃えるゴミを出す\n・09:15 将生：コドモン入力%' then raise exception 'FAIL focus morning block: %', focus; end if;
  if focus not like E'%夜にやること\n・3件%' or focus like '%お風呂%' or focus like '%余裕があれば%' or focus like '%明日%' then
    raise exception 'FAIL focus trims the rest: %', focus; end if;
  if position('⏰' in focus) > position('夜にやること' in focus) then raise exception 'FAIL focus order'; end if;
  if whole_text like '%⏰%' or whole_text not like '%お風呂%' or whole_text not like '%余裕があれば%' or whole_text not like '%明日%' then
    raise exception 'FAIL the 今日 reply must stay full: %', whole_text; end if;
end $$;
reset role;
rollback;
select 'morning_focus_and_nudge: PASS' as result;

\set ON_ERROR_STOP on
begin;
do $$
declare brief jsonb; evening text; morning text;
begin
  brief:=jsonb_build_object('own_task_groups',jsonb_build_object(
    'morning',jsonb_build_array(jsonb_build_object('title','朝の作業')),
    'daytime',jsonb_build_array(jsonb_build_object('title','昼の作業')),
    'evening',jsonb_build_array(jsonb_build_object('title','夜の作業')),
    'optional','[]'::jsonb),
    'special_today',jsonb_build_array(jsonb_build_object('title','今日の特別予定')),
    'schedule',jsonb_build_array(jsonb_build_object('title','家族の予定')));
  evening:=private.fn_render_daily_brief_text_v4(brief,'evening');
  if evening like '%朝の残り%' or evening like '%日中の残り%' or evening like '%朝の作業%' or evening like '%昼の作業%'
    then raise exception 'earlier work was repeated: %',evening; end if;
  if evening not like '%夜の作業%' or evening not like '%家族の予定%' or evening not like '%⭐ 今日だけの予定%'
    or evening not like '%今日の特別予定%' or evening like '%忘れずに%' then raise exception 'evening information was lost: %',evening; end if;
  morning:=private.fn_render_daily_brief_text_v4(brief,'morning');
  if morning not like '%朝の作業%' or morning not like '%昼の作業%' or morning not like '%⭐ 今日だけの予定%'
    then raise exception 'morning information was lost: %',morning; end if;
end $$;
rollback;
select 'evening_without_morning_carryover: PASS' as result;

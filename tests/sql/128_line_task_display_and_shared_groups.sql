\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  u1 uuid:=gen_random_uuid(); u2 uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  h uuid; other_h uuid; ar1 uuid; ar2 uuid; token text;
  first_t uuid; shared_t uuid; claimed_t uuid; mine_t uuid; optional_claimed_t uuid; codmon_t uuid; prep_t uuid; foreign_t uuid;
  burnable_t uuid; recycling_t uuid;
  codmon_def uuid; native_title text; items jsonb; item jsonb; b jsonb; rendered text; day date:='2026-10-13';
begin
  insert into auth.users(id) values(u1),(u2),(outsider);
  h:=(public.server_tx_create_household(u1,gen_random_uuid(),'Line display','Papa')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(u1,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(u2,gen_random_uuid(),token,'Mama');
  update public.household_members set family_role=case user_id when u1 then 'papa' else 'mama' end where household_id=h;
  other_h:=(public.server_tx_create_household(outsider,gen_random_uuid(),'Foreign','Other')->>'household_id')::uuid;
  perform private.backfill_canonical_foundation_v1();
  select id into ar1 from public.domain_actor_refs where household_id=h and real_user_id=u1 and actor_kind='real_user';
  select id into ar2 from public.domain_actor_refs where household_id=h and real_user_id=u2 and actor_kind='real_user';
  first_t:=(public.server_tx_create_task(u1,gen_random_uuid(),'食洗機を空ける（先に家を出る人）','housework',day,null,null,'whole','morning',null)->>'task_id')::uuid;
  shared_t:=(public.server_tx_create_task(u1,gen_random_uuid(),'コープ申し込み','housework',day,null,null,'whole','evening',null)->>'task_id')::uuid;
  claimed_t:=(public.server_tx_create_task(u1,gen_random_uuid(),'相手が対応中の作業','housework',day,null,null,'whole','morning',null)->>'task_id')::uuid;
  mine_t:=(public.server_tx_create_task(u1,gen_random_uuid(),'自分が対応中の作業','housework',day,null,null,'whole','morning',null)->>'task_id')::uuid;
  optional_claimed_t:=(public.server_tx_create_task(u1,gen_random_uuid(),'相手が始めた任意の窓拭き','housework',day,null,null,'whole','anytime',null)->>'task_id')::uuid;
  burnable_t:=(public.server_tx_create_task(u1,gen_random_uuid(),'燃えるゴミのゴミ出し','garbage',day,null,u1,'whole','morning',null)->>'task_id')::uuid;
  recycling_t:=(public.server_tx_create_task(u1,gen_random_uuid(),'缶・ペットボトル・段ボールのゴミ出し','garbage',day,null,u1,'whole','morning',null)->>'task_id')::uuid;
  update public.task_instances set assignment_mode='anyone',planned_assignee_id=null,planned_assignee_actor_ref_id=null where id in (first_t,shared_t,claimed_t,mine_t);
  update public.task_instances set active_claimant_actor_ref_id=ar2,claimed_at=now() where id=claimed_t;
  update public.task_instances set active_claimant_actor_ref_id=ar1,claimed_at=now() where id=mine_t;
  update public.task_instances set assignment_mode='anyone',planned_assignee_id=null,planned_assignee_actor_ref_id=null,
    expectation='optional',active_claimant_actor_ref_id=ar2,claimed_at=now() where id=optional_claimed_t;
  select id into codmon_def from public.task_definitions where household_id=h and code='codmon_submit';
  if codmon_def is null then
    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by)
    values(h,'codmon_submit','コドモン送信（将生・詩乃がそろってから）','nursery','morning','whole',u1) returning id into codmon_def;
  end if;
  codmon_t:=(public.server_tx_create_task(u1,gen_random_uuid(),'コドモン送信（将生・詩乃がそろってから）','nursery',day,null,u1,'whole','morning',null)->>'task_id')::uuid;
  update public.task_instances set task_definition_id=codmon_def where id=codmon_t;
  prep_t:=(public.server_tx_create_task(u1,gen_random_uuid(),'明日の保育園準備（持ち物・着替え）','preparation',day+1,
    time '21:00',u1,'whole','evening',null)->>'task_id')::uuid;
  foreign_t:=(public.server_tx_create_task(outsider,gen_random_uuid(),'外国の秘密の作業','housework',day,null,outsider,'whole','morning',null)->>'task_id')::uuid;

  items:=public.server_read_line_tasks_display(u1,day);
  select value into item from jsonb_array_elements(items) where value->>'task_id'=first_t::text;
  if item is null or item->>'title'<>'食洗機を空ける（先に家を出る人）' or item->>'display_title'<>'食洗機を空ける'
    or item->>'responsibility_hint'<>'先に家を出る人' or item->>'assignment_mode'<>'anyone' then
    raise exception 'FAIL: first departure display weakened or changed stored title: %',item; end if;
  select value into item from jsonb_array_elements(items) where value->>'task_id'=shared_t::text;
  if item is null or item->>'responsibility_hint'<>'2人で分担（誰でもOK）' then raise exception 'FAIL: unrestricted sharing lacks distinct instruction'; end if;
  select value into item from jsonb_array_elements(items) where value->>'task_id'=claimed_t::text;
  if item is null or item->>'active_claimant_user_id'<>u2::text or item->>'active_claimant_label'<>'ママ' then raise exception 'FAIL: claimant presentation lost'; end if;
  select value into item from jsonb_array_elements(items) where value->>'task_id'=codmon_t::text;
  if item is null or item->>'display_title'<>'コドモンを送信（2人分の入力がそろってから）' then raise exception 'FAIL: Codmon input condition remains ambiguous'; end if;
  select value into item from jsonb_array_elements(items) where value->>'task_id'=burnable_t::text;
  if item is null or item->>'display_title'<>'燃えるゴミを出す' or item->>'title'<>'燃えるゴミのゴミ出し' then
    raise exception 'FAIL: burnable-garbage copy did not improve without rewriting the stored title'; end if;
  select value into item from jsonb_array_elements(items) where value->>'task_id'=recycling_t::text;
  if item is null or item->>'display_title'<>'缶・ペットボトル・段ボールを出す' or item->>'title'<>'缶・ペットボトル・段ボールのゴミ出し' then
    raise exception 'FAIL: recycling copy did not improve without rewriting the stored title'; end if;
  if items::text like '%外国の秘密%' then raise exception 'FAIL: conversational reader crossed household'; end if;
  item:=private.fn_task_display_items_v1(h,jsonb_build_array(jsonb_build_object('task_id',foreign_t,'title','untrusted')))->0;
  if item ? 'display_title' then raise exception 'FAIL: presentation lookup exposes another household'; end if;

  b:=public.server_read_daily_brief(u1,day);
  select value into item from jsonb_array_elements(b->'tasks') where value->>'task_id'=first_t::text;
  if item is null or item->>'display_title'<>'食洗機を空ける' or item->>'title' not like '%誰でもOK%' then
    raise exception 'FAIL: canonical projection missing or legacy title unexpectedly changed: %',item; end if;
  select value into item from jsonb_array_elements(b#>'{tomorrow_impact,tasks}') where value->>'task_id'=prep_t::text;
  if item is null or item->>'display_title'<>'10/15(木)の保育園準備（持ち物・着替え）' or item->>'scheduled_date'<>'2026-10-14'
    or item->>'preparation_target_date'<>'2026-10-15' then raise exception 'FAIL: tomorrow execution day confused with preparation target day: %',item; end if;
  rendered:=private.fn_render_daily_brief_text_v4(private.fn_brief_split_special_v1(b),'morning');
  if rendered not like '%⭐ 今日、忘れずに%' or rendered like '%平日は毎日ないこと%'
    or rendered like '%食洗機を空ける（誰でもOK）%' or rendered not like '%先に家を出る人%'
    or rendered not like '%2人で分担（誰でもOK）%' then raise exception 'FAIL: task instruction grouping remains ambiguous: %',rendered; end if;
  if rendered not like '%明日 10/14(水)の予定・作業%21:00 10/15(木)の保育園準備%'
    or rendered not like '%相手が対応中の作業（ママ対応中）%'
    or rendered not like '%自分が対応中の作業（パパ対応中）%' then raise exception 'FAIL: target dates or claimant labels lost: %',rendered; end if;
  if position('相手が対応中の作業' in rendered)<position('相手の担当で確認したいこと' in rendered) then
    raise exception 'FAIL: other claimant task remains in own section'; end if;
  if rendered not like '%相手の担当で確認したいこと%◦相手が始めた任意の窓拭き（余裕があれば／ママ対応中）%'
    or (length(rendered)-length(replace(rendered,'相手が始めた任意の窓拭き','')))/length('相手が始めた任意の窓拭き')<>1 then
    raise exception 'FAIL: optional other claimant vanished or was duplicated as required work: %',rendered; end if;
  b:=public.server_tx_get_week_schedule(u1,day+1,day+1);
  select value into item from jsonb_array_elements(b->'assignments') where value->>'task_instance_id'=prep_t::text;
  if item is null or item->>'display_title'<>'10/15(木)の保育園準備（持ち物・着替え）'
    or item->>'title'<>'明日の保育園準備（持ち物・着替え）'
    or item->>'scheduled_date'<>'2026-10-14' or item->>'planned_assignee_id'<>u1::text then
    raise exception 'FAIL: dated schedule reply still confuses preparation dates or changes assignment: %',item; end if;

  -- Presentation never rewrites the original task, assignment or calendar truth.
  select title into native_title from public.task_instances where id=prep_t;
  if native_title<>'明日の保育園準備（持ち物・着替え）' then raise exception 'FAIL: rendering mutated preparation title'; end if;
  update public.task_instances set title='独自のコドモン送信名' where id=codmon_t;
  item:=private.fn_task_display_items_v1(h,jsonb_build_array(jsonb_build_object('task_id',codmon_t)))->0;
  if item->>'display_title'<>'独自のコドモン送信名' then raise exception 'FAIL: custom title overwritten'; end if;
  update public.task_instances set title='コドモン送信（将生・詩乃がそろってから）',assignment_mode='unassigned',
    planned_assignee_id=null,planned_assignee_actor_ref_id=null where id=codmon_t;
  b:=public.server_read_daily_brief(u1,day);
  rendered:=private.fn_daily_brief_urgent_lines_v2(b->'urgent_actions');
  if rendered not like '%コドモンを送信（2人分の入力がそろってから）%' then
    raise exception 'FAIL: urgent Codmon assignment still has ambiguous wording: %',rendered; end if;
  if private.fn_line_task_lines_v1(jsonb_build_array(jsonb_build_object('shared_text','17時に迎え予定が変わる')))<>'・17時に迎え予定が変わる' then
    raise exception 'FAIL: unknown shared-information fallback lost'; end if;
  if has_function_privilege('anon','public.server_read_line_tasks_display(uuid,date)','EXECUTE')
    or has_function_privilege('authenticated','public.server_read_line_tasks_display(uuid,date)','EXECUTE')
    or not has_function_privilege('service_role','public.server_read_line_tasks_display(uuid,date)','EXECUTE') then
    raise exception 'FAIL: worker presentation reader grants changed'; end if;
end $$;
reset role;
rollback;
select 'line_task_display_and_shared_groups: PASS' as result;

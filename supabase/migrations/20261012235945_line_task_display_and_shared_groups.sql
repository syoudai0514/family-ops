-- Presentation only: preserve stored titles, assignment rules and business state.
-- Shared tasks can have a concrete household instruction (first departure)
-- while still allowing either adult to record doing them.
create or replace function private.fn_task_display_items_v1(p_household_id uuid, p_items jsonb)
returns jsonb language sql stable security invoker set search_path = '' as $$
  with items as (
    select item, ord, t.*, d.code as task_code,
      ar.real_user_id as claimant_user_id,
      case hm.family_role when 'papa' then 'パパ' when 'mama' then 'ママ'
        else coalesce(nullif(p.display_name,''),'家族') end as claimant_label
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) with ordinality x(item,ord)
    left join public.task_instances t on t.household_id=p_household_id
      and t.id=nullif(coalesce(item->>'task_id',item->>'task_instance_id',item->>'id'),'')::uuid and t.test_context_id is null
    left join public.task_definitions d on d.household_id=t.household_id and d.id=t.task_definition_id
    left join public.domain_actor_refs ar on ar.household_id=t.household_id and ar.id=t.active_claimant_actor_ref_id
      and ar.actor_kind='real_user' and ar.test_context_id is null
    left join public.household_members hm on hm.household_id=t.household_id and hm.user_id=ar.real_user_id
    left join public.profiles p on p.user_id=ar.real_user_id
  ), projected as (
    select *, case
      when title='燃えるゴミのゴミ出し' then '燃えるゴミを出す'
      when title='缶・ペットボトル・段ボールのゴミ出し' then '缶・ペットボトル・段ボールを出す'
      when title='コドモン送信（将生・詩乃がそろってから）' and task_code='codmon_submit'
        then 'コドモンを送信（2人分の入力がそろってから）'
      when title in ('明日の保育園準備','明日の保育園準備（持ち物・着替え）')
        then to_char(scheduled_date+1,'FMMM/FMDD') || '(' || (array['月','火','水','木','金','土','日'])[extract(isodow from scheduled_date+1)::int]
          || ')の保育園準備' || case when title like '%（持ち物・着替え）' then '（持ち物・着替え）' else '' end
      when assignment_mode='anyone' and title='食洗機を空ける（先に家を出る人）'
        then '食洗機を空ける'
      else title end as display_title,
      case when assignment_mode='anyone' and title='食洗機を空ける（先に家を出る人）' then '先に家を出る人'
        when assignment_mode='anyone' then '2人で分担（誰でもOK）'
        when planned_assignee_id is null then '担当未定' else null end as responsibility_hint
    from items
  )
  select coalesce(jsonb_agg(case when id is null then item else item || jsonb_build_object(
    'display_title',display_title,'responsibility_hint',responsibility_hint,
    'task_code',task_code,'scheduled_date',scheduled_date,'due_at',due_at,
    'assignment_mode',assignment_mode,'planned_assignee_id',planned_assignee_id,
    'active_claimant_user_id',claimant_user_id,
    'active_claimant_label',case when claimant_user_id is not null then claimant_label end,
    'preparation_target_date',case when title in ('明日の保育園準備','明日の保育園準備（持ち物・着替え）') then scheduled_date+1 end
  ) end order by ord),'[]'::jsonb) from projected;
$$;
revoke all on function private.fn_task_display_items_v1(uuid,jsonb) from public,anon,authenticated;
grant execute on function private.fn_task_display_items_v1(uuid,jsonb) to service_role;

-- This extra presentation contract leaves existing title/action-target fields intact.
alter function public.server_read_daily_brief(uuid,date) rename to server_read_daily_brief_pre_task_display_v1;
revoke all on function public.server_read_daily_brief_pre_task_display_v1(uuid,date) from public,anon,authenticated;
grant execute on function public.server_read_daily_brief_pre_task_display_v1(uuid,date) to service_role;
create or replace function public.server_read_daily_brief(p_actor_id uuid,p_local_date date default null)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  b jsonb; h uuid; k text; groups jsonb; tomorrow jsonb; partner jsonb; sections jsonb;
begin
  b:=public.server_read_daily_brief_pre_task_display_v1(p_actor_id,p_local_date);
  select household_id into h from public.household_members where user_id=p_actor_id;
  if h is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  for k in select unnest(array['tasks','already_handled','waiting_checks','carryovers','carryover','urgent_actions']) loop
    if b ? k then b:=jsonb_set(b,array[k],private.fn_task_display_items_v1(h,b->k)); end if;
  end loop;
  groups:=coalesce(b->'own_task_groups','{}'::jsonb);
  for k in select unnest(array['morning','daytime','evening','optional']) loop
    groups:=jsonb_set(groups,array[k],private.fn_task_display_items_v1(h,groups->k));
  end loop;
  tomorrow:=coalesce(b->'tomorrow_impact','{}'::jsonb);
  for k in select unnest(array['tasks','carryovers']) loop
    tomorrow:=jsonb_set(tomorrow,array[k],private.fn_task_display_items_v1(h,tomorrow->k));
  end loop;
  partner:=coalesce(b->'partner_summary','{}'::jsonb);
  partner:=jsonb_set(partner,'{critical_items}',private.fn_task_display_items_v1(h,partner->'critical_items'));
  sections:=coalesce(b->'sections','{}'::jsonb)||jsonb_build_object(
    'own_task_groups',groups,'tomorrow_impact',tomorrow,'partner_summary',partner);
  return b||jsonb_build_object('own_task_groups',groups,'tomorrow_impact',tomorrow,
    'partner_summary',partner,'sections',sections,'display_recipient_user_id',p_actor_id);
end $$;
revoke all on function public.server_read_daily_brief(uuid,date) from public,anon,authenticated;
grant execute on function public.server_read_daily_brief(uuid,date) to service_role;

-- The conversational full list includes completed work. Its display fields
-- come from the same scoped projection as the scheduled brief and PWA.
create or replace function public.server_read_line_tasks_display(p_actor_id uuid,p_local_date date)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare h uuid; items jsonb;
begin
  if p_actor_id is null or p_local_date is null then raise exception 'INVALID_INPUT'; end if;
  select household_id into h from public.household_members where user_id=p_actor_id;
  if h is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('task_id',t.id,'title',t.title,
    'status',t.status,'outcome_reason',t.outcome_reason,'routine_phase',t.routine_phase,
    'expectation',t.expectation) order by t.due_at nulls last,t.title,t.id),'[]'::jsonb)
  into items from public.task_instances t where t.household_id=h and t.scheduled_date=p_local_date
    and t.test_context_id is null and t.status in ('todo','in_progress','completed','skipped');
  return private.fn_task_display_items_v1(h,items);
end $$;
revoke all on function public.server_read_line_tasks_display(uuid,date) from public,anon,authenticated;
grant execute on function public.server_read_line_tasks_display(uuid,date) to service_role;

create or replace function private.fn_daily_brief_lines_v1(p_items jsonb)
returns text language sql immutable security invoker set search_path = '' as $$
  select string_agg('・'||coalesce(nullif(item->>'display_title',''),nullif(item->>'title',''),
    nullif(item->>'shared_title',''),nullif(item->>'shared_text',''),nullif(item->>'message',''),
    nullif(item->>'detail',''),nullif(item->>'waiting_note',''),nullif(item->>'name',''),'確認が必要な項目'),
    E'\n' order by ord)
  from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) with ordinality x(item,ord);
$$;
revoke all on function private.fn_daily_brief_lines_v1(jsonb) from public,anon,authenticated;
grant execute on function private.fn_daily_brief_lines_v1(jsonb) to service_role;

create or replace function private.fn_line_task_lines_v1(p_items jsonb,p_show_time boolean default false,p_quiet boolean default false)
returns text language sql immutable security invoker set search_path = '' as $$
  select string_agg(case when p_quiet or item->>'expectation'='optional' then '◦' else '・' end
    || case when p_show_time and nullif(item->>'due_at','') is not null
      then to_char((item->>'due_at')::timestamptz at time zone 'Asia/Tokyo','HH24:MI')||' ' else '' end
    || coalesce(nullif(item->>'display_title',''),nullif(item->>'title',''),nullif(item->>'shared_title',''),
      nullif(item->>'shared_text',''),nullif(item->>'message',''),nullif(item->>'detail',''),
      nullif(item->>'waiting_note',''),nullif(item->>'name',''),'確認が必要な項目')
    || case when nullif(item->>'active_claimant_label','') is not null
      then '（'||case when not p_quiet and item->>'expectation'='optional' then '余裕があれば／' else '' end
        ||(item->>'active_claimant_label')||'対応中）' else '' end,
    E'\n' order by ord)
  from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) with ordinality x(item,ord);
$$;
revoke all on function private.fn_line_task_lines_v1(jsonb,boolean,boolean) from public,anon,authenticated;
grant execute on function private.fn_line_task_lines_v1(jsonb,boolean,boolean) to service_role;

-- Render a task collection by the household instruction, not by repeating a
-- generic assignment label on each line. A claimed task stays with its taker.
create or replace function private.fn_line_task_groups_v1(p_items jsonb,p_recipient text,p_show_time boolean default false)
returns text language plpgsql immutable security invoker set search_path = '' as $$
declare out_text text:=''; part text; a jsonb; instruction text;
begin
  select coalesce(jsonb_agg(item order by ord),'[]'::jsonb) into a
  from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) with ordinality x(item,ord)
  where item->>'assignment_mode' is distinct from 'anyone'
    or (nullif(item->>'active_claimant_user_id','') is not null and (p_recipient is null or item->>'active_claimant_user_id'=p_recipient));
  out_text:=coalesce(private.fn_line_task_lines_v1(a,p_show_time),'');
  for instruction in select unnest(array['先に家を出る人','2人で分担（誰でもOK）']) loop
    select coalesce(jsonb_agg(item order by ord),'[]'::jsonb) into a
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) with ordinality x(item,ord)
    where item->>'assignment_mode'='anyone' and nullif(item->>'active_claimant_user_id','') is null
      and coalesce(item->>'responsibility_hint','2人で分担（誰でもOK）')=instruction;
    part:=private.fn_line_task_lines_v1(a,p_show_time);
    if part is not null then out_text:=concat_ws(E'\n',nullif(out_text,''),instruction,part); end if;
  end loop;
  return nullif(out_text,'');
end $$;
revoke all on function private.fn_line_task_groups_v1(jsonb,text,boolean) from public,anon,authenticated;
grant execute on function private.fn_line_task_groups_v1(jsonb,text,boolean) to service_role;

create or replace function private.fn_render_daily_brief_text_v4(p_brief jsonb,p_mode text)
returns text language plpgsql immutable security invoker set search_path = '' as $$
declare
  mode text:=case when p_mode in ('morning','daytime','evening') then p_mode else 'daytime' end;
  body text:=case mode when 'morning' then '朝のおうちノート' when 'evening' then '夜のおうちノート' else '今日のおうちノート' end;
  part text; phase text; heading text; recipient text:=p_brief->>'display_recipient_user_id';
  all_tasks jsonb; partner_items jsonb; optional_items jsonb; tomorrow jsonb; tomorrow_date date;
begin
  part:=private.fn_daily_brief_urgent_lines_v2(p_brief->'urgent_actions');
  if part is not null then body:=body||E'\n\nまず確認\n'||part; end if;
  part:=private.fn_line_task_groups_v1(p_brief->'special_today',recipient,true);
  if part is not null then body:=body||E'\n\n⭐ 今日、忘れずに\n'||part; end if;
  part:=private.fn_daily_brief_lines_v1(coalesce(p_brief->'exceptions','[]'::jsonb)||coalesce(p_brief->'carryovers','[]'::jsonb));
  if part is not null then body:=body||E'\n\nいつもと違うこと\n'||part; end if;
  part:=private.fn_daily_brief_lines_v1(p_brief->'schedule');
  if part is not null then body:=body||E'\n\n今日の予定\n'||part; end if;
  if mode='morning' then
    part:=private.fn_daily_brief_lines_v1(p_brief->'already_handled');
    if part is not null then body:=body||E'\n\nもう済んでいる\n'||part; end if;
  end if;
  part:=private.fn_daily_brief_lines_v1(p_brief->'waiting_checks');
  if part is not null then body:=body||E'\n\n待ち・確認\n'||part; end if;
  for phase in select unnest(array['morning','daytime','evening']) loop
    heading:=case phase when 'morning' then case mode when 'morning' then '朝やること' else '朝の残り' end
      when 'daytime' then case mode when 'evening' then '日中の残り' when 'daytime' then '今やること' else '日中にやること' end
      else case mode when 'daytime' then 'このあと（夜）' else '夜にやること' end end;
    part:=private.fn_line_task_groups_v1(p_brief->'own_task_groups'->phase,recipient);
    if part is not null then body:=body||E'\n\n'||heading||E'\n'||part; end if;
  end loop;
  part:=private.fn_daily_brief_handover_lines_v1(p_brief->'active_infos');
  if part is not null then body:=body||E'\n\n引き継ぎ・共有\n'||part; end if;
  select coalesce(jsonb_agg(item order by ord),'[]'::jsonb) into optional_items
  from jsonb_array_elements(coalesce(p_brief->'own_task_groups'->'optional','[]'::jsonb)) with ordinality x(item,ord)
  where nullif(item->>'active_claimant_user_id','') is null or recipient is null or item->>'active_claimant_user_id'=recipient;
  part:=private.fn_line_task_lines_v1(optional_items,false,true);
  if part is not null then body:=body||E'\n\n余裕があれば\n'||part; end if;

  all_tasks:=coalesce(p_brief->'special_today','[]'::jsonb)||coalesce(p_brief->'own_task_groups'->'morning','[]'::jsonb)
    ||coalesce(p_brief->'own_task_groups'->'daytime','[]'::jsonb)||coalesce(p_brief->'own_task_groups'->'evening','[]'::jsonb)
    ||coalesce(p_brief->'own_task_groups'->'optional','[]'::jsonb);
  select coalesce(jsonb_agg(item order by ord),'[]'::jsonb) into partner_items
  from (select distinct on (coalesce(item->>'task_id',item->>'title')) item,ord
    from jsonb_array_elements(coalesce(p_brief->'partner_summary'->'critical_items','[]'::jsonb)||all_tasks) with ordinality x(item,ord)
    where ord<=jsonb_array_length(coalesce(p_brief->'partner_summary'->'critical_items','[]'::jsonb))
      or (recipient is not null and nullif(item->>'active_claimant_user_id','') is not null and item->>'active_claimant_user_id'<>recipient)
    order by coalesce(item->>'task_id',item->>'title'),ord) unique_items;
  part:=private.fn_line_task_lines_v1((select coalesce(jsonb_agg(item order by ord),'[]'::jsonb)
    from jsonb_array_elements(partner_items) with ordinality x(item,ord) where ord<=3));
  if part is not null then
    body:=body||E'\n\n相手の担当で確認したいこと\n'||part;
    if jsonb_array_length(partner_items)>3 then body:=body||E'\n・ほか '||(jsonb_array_length(partner_items)-3)::text||'件'; end if;
  end if;
  tomorrow:=coalesce(p_brief->'tomorrow_impact','{}'::jsonb);
  tomorrow_date:=nullif(tomorrow->>'local_date','')::date;
  part:=private.fn_line_task_lines_v1(coalesce(tomorrow->'tasks','[]'::jsonb)||coalesce(tomorrow->'schedule','[]'::jsonb)
    ||coalesce(tomorrow->'carryovers','[]'::jsonb),true);
  if part is not null then
    heading:=case when tomorrow_date is null then '明日の予定・作業' else '明日 '||to_char(tomorrow_date,'FMMM/FMDD')
      ||'('||(array['月','火','水','木','金','土','日'])[extract(isodow from tomorrow_date)::int]||')の予定・作業' end;
    body:=body||E'\n\n'||heading||E'\n'||part;
  end if;
  if coalesce((p_brief#>>'{reconciliation,remaining_count}')::integer,0)>0 then
    body:=body||E'\n\n朝・夜の記録\n・未確認 '||(p_brief#>>'{reconciliation,remaining_count}')||'件';
  end if;
  if mode='evening' then
    part:=private.fn_daily_brief_lines_v1(p_brief->'shopping');
    if part is not null then body:=body||E'\n\n買い物\n'||part; end if;
  end if;
  return left(body,5000);
end $$;
revoke all on function private.fn_render_daily_brief_text_v4(jsonb,text) from public,anon,authenticated;
grant execute on function private.fn_render_daily_brief_text_v4(jsonb,text) to service_role;

-- The conversational brief and scheduled brief now share their wording.
-- The existing Codmon readiness acknowledgement remains a separate section.
create or replace function public.server_render_daily_brief_text(p_actor_id uuid,p_local_date date default null)
returns text language plpgsql stable security invoker set search_path = '' as $$
declare b jsonb; mode text; hour integer:=(extract(hour from now() at time zone 'Asia/Tokyo'))::integer;
begin
  b:=public.server_read_daily_brief(p_actor_id,p_local_date);
  mode:=case when hour<12 then 'morning' when hour<18 then 'daytime' else 'evening' end;
  return left(private.fn_render_daily_brief_text_v4(b,mode)||private.fn_render_codmon_readiness_text_v1(b->'codmon'),5000);
end $$;
revoke all on function public.server_render_daily_brief_text(uuid,date) from public,anon,authenticated;
grant execute on function public.server_render_daily_brief_text(uuid,date) to service_role;

-- Dated schedule replies can contain assigned preparation chores as well as
-- calendar-visible events. Keep their execution date and original fields, but
-- use the same explicit preparation target date as the daily brief.
alter function public.server_tx_get_week_schedule(uuid,date,date) rename to server_tx_get_week_schedule_pre_task_display_v1;
revoke all on function public.server_tx_get_week_schedule_pre_task_display_v1(uuid,date,date) from public,anon,authenticated;
grant execute on function public.server_tx_get_week_schedule_pre_task_display_v1(uuid,date,date) to service_role;
create or replace function public.server_tx_get_week_schedule(p_actor_id uuid,p_start_date date,p_end_date date)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare b jsonb; h uuid;
begin
  b:=public.server_tx_get_week_schedule_pre_task_display_v1(p_actor_id,p_start_date,p_end_date);
  select household_id into h from public.household_members where user_id=p_actor_id;
  return b||jsonb_build_object('assignments',private.fn_task_display_items_v1(h,b->'assignments'));
end $$;
revoke all on function public.server_tx_get_week_schedule(uuid,date,date) from public,anon,authenticated;
grant execute on function public.server_tx_get_week_schedule(uuid,date,date) to service_role;

-- Urgent task headings use the same wording, without changing request states
-- or command targets. Unknown shared information retains its existing fallback.
create or replace function private.fn_daily_brief_urgent_lines_v2(p_items jsonb)
returns text language sql immutable security invoker set search_path = '' as $$
  with normalized as (
    select item,ord,item->>'kind' as kind,coalesce(nullif(item->>'routine_phase',''),'other') as phase,
      coalesce(nullif(item->>'display_title',''),nullif(item->>'title',''),nullif(item->>'shared_title',''),
        nullif(item->>'message',''),'確認が必要な項目') as label,
      case item->>'state' when 'pending' then '返事待ち' when 'checking' then '確認中'
        when 'consulting' then '相談中' when 'awaiting_confirmation' then '確認待ち' else null end as state_label
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) with ordinality x(item,ord)
  ), ordinary as (
    select string_agg('・'||label||case when state_label is not null then '（'||state_label||'）' else '' end,E'\n' order by ord) as lines
    from normalized where kind is distinct from 'assignment_needed'
  ), assignment_groups as (
    select phase,min(ord) as first_ord,string_agg('・'||label,E'\n' order by ord) as lines
    from normalized where kind='assignment_needed' group by phase
  ), assignments as (
    select string_agg('担当未定（'||case phase when 'morning' then '朝' when 'evening' then '夜' else '日中' end||'）'||E'\n'||lines,
      E'\n' order by case phase when 'morning' then 1 when 'evening' then 3 else 2 end,first_ord) as lines
    from assignment_groups
  )
  select nullif(concat_ws(E'\n',ordinary.lines,assignments.lines),'') from ordinary cross join assignments;
$$;
revoke all on function private.fn_daily_brief_urgent_lines_v2(jsonb) from public,anon,authenticated;
grant execute on function private.fn_daily_brief_urgent_lines_v2(jsonb) to service_role;

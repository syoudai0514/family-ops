\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  actor uuid:=gen_random_uuid(); partner uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  household uuid; other_household uuid; token text; task uuid; req uuid; operation uuid:=gen_random_uuid();
  response jsonb; candidates jsonb; blocked boolean:=false;
begin
  insert into auth.users(id) values(actor),(partner),(outsider);
  household:=(public.server_tx_create_household(actor,gen_random_uuid(),'Thanks','パパ')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(actor,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(partner,gen_random_uuid(),token,'ママ');
  other_household:=(public.server_tx_create_household(outsider,gen_random_uuid(),'Other','Other')->>'household_id')::uuid;
  insert into private.line_user_links(household_id,user_id,line_user_id,status) values(household,partner,'LINE-THANKS','active');
  update public.notification_preferences set request_line=false where household_id=household and user_id=partner;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,completion_mode,status,source,created_by,planned_assignee_id,assignment_mode)
  values(household,'manual','お迎え','pickup','evening',current_date,'whole','todo','test',actor,actor,'person') returning id into task;
  update public.task_instances set status='completed',completed_at=now(),actual_completed_by_id=partner where id=task;
  if jsonb_array_length(public.server_read_thanks_candidates(actor,(now() at time zone 'Asia/Tokyo')::date-1))<>0 then
    raise exception 'morning follow-up included the wrong day';
  end if;
  candidates:=public.server_read_thanks_candidates(actor);
  if not candidates @> jsonb_build_array(jsonb_build_object('kind','task','id',task,'recipient_id',partner)) then
    raise exception 'eligible thanks missing: %',candidates;
  end if;
  response:=public.server_tx_send_thanks(actor,operation,'task',task,null);
  if response->>'sent'<>'true' then raise exception 'thanks failed %',response; end if;
  if not exists(select 1 from public.user_notifications where household_id=household and recipient_user_id=partner and type='thanks' and body like '%お迎え、ありがとう。%') then
    raise exception 'thanks notification missing';
  end if;
  if exists(select 1 from private.notification_outbox where household_id=household and recipient_user_id=partner and type='thanks') then
    raise exception 'LINE off was ignored';
  end if;
  perform public.server_tx_send_thanks(actor,operation,'task',task,null);
  perform public.server_tx_send_thanks(actor,gen_random_uuid(),'task',task,null);
  if (select count(*) from public.user_notifications where household_id=household and type='thanks')<>1 then
    raise exception 'duplicate thanks';
  end if;
  begin
    perform public.server_tx_send_thanks(outsider,gen_random_uuid(),'task',task,null);
  exception when others then blocked:=true;
  end;
  if not blocked then raise exception 'foreign household sent thanks'; end if;
  if has_function_privilege('authenticated','public.server_tx_send_thanks(uuid,uuid,text,uuid,text)','execute')
    or has_function_privilege('authenticated','public.server_read_thanks_candidates(uuid,date)','execute') then
    raise exception 'thanks command exposed to clients';
  end if;
  if jsonb_array_length(public.server_read_thanks_candidates(actor))<>0 then raise exception 'already thanked candidate remains'; end if;
  blocked:=false;
  begin
    perform public.server_tx_send_thanks(actor,operation,'task',task,'different');
  exception when others then blocked:=true;
  end;
  if not blocked then raise exception 'operation id accepted different payload'; end if;

  update public.notification_preferences set request_line=true where household_id=household and user_id=partner;
  insert into public.requests(household_id,requester_id,recipient_id,shared_title,shared_message,status,accepted_at)
  values(household,actor,partner,'持ち物','お願い','accepted',now()) returning id into req;
  if not public.server_read_thanks_candidates(actor) @> jsonb_build_array(jsonb_build_object('kind','request','id',req)) then
    raise exception 'accepted request candidate missing';
  end if;
  perform public.server_tx_send_thanks(actor,gen_random_uuid(),'request',req,'助かったよ');
  if not exists(select 1 from public.user_notifications where household_id=household and type='thanks' and body like '%持ち物、ありがとう。%' and body like '%助かったよ%') then
    raise exception 'request thanks or note missing';
  end if;
  if not exists(select 1 from private.notification_outbox where household_id=household and recipient_user_id=partner and type='thanks') then
    raise exception 'LINE enabled thanks did not enqueue';
  end if;
end $$;
rollback;
select 'thanks: PASS' as result;

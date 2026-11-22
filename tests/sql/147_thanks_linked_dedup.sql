\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  actor uuid:=gen_random_uuid(); partner uuid:=gen_random_uuid(); h uuid; token text;
  task1 uuid; task2 uuid; request1 uuid; request2 uuid; candidates jsonb; result jsonb;
  today date:=(now() at time zone 'Asia/Tokyo')::date;
begin
  insert into auth.users(id) values(actor),(partner);
  h:=(public.server_tx_create_household(actor,gen_random_uuid(),'Linked thanks','パパ')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(actor,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(partner,gen_random_uuid(),token,'ママ');
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,completion_mode,status,source,created_by,planned_assignee_id,assignment_mode)
  values(h,'manual','送り','dropoff','morning',today,'whole','todo','test',actor,actor,'person') returning id into task1;
  insert into public.requests(household_id,requester_id,recipient_id,shared_title,status,accepted_at,linked_task_instance_id)
  values(h,actor,partner,'送り','accepted',now()-interval '1 day',task1) returning id into request1;

  candidates:=public.server_read_thanks_candidates(actor);
  if jsonb_array_length(candidates)<>1 or not candidates @> jsonb_build_array(jsonb_build_object('kind','request','id',request1)) then
    raise exception 'accepted request before completion should be a candidate: %',candidates;
  end if;
  update public.task_instances set status='completed',completed_at=now(),actual_completed_by_id=partner where id=task1;

  candidates:=public.server_read_thanks_candidates(actor);
  if jsonb_array_length(candidates)<>1 or not candidates @> jsonb_build_array(jsonb_build_object('kind','task','id',task1)) then
    raise exception 'linked task and request not combined: %',candidates;
  end if;
  if not public.server_read_thanks_candidates(actor,today) @> jsonb_build_array(jsonb_build_object('kind','task','id',task1)) then
    raise exception 'completion day follow-up lost';
  end if;
  perform public.server_tx_send_thanks(actor,gen_random_uuid(),'task',task1,null);
  result:=public.server_tx_send_thanks(actor,gen_random_uuid(),'request',request1,null);
  if result->>'already_sent'<>'true' or (select count(*) from public.user_notifications where household_id=h and type='thanks')<>1 then
    raise exception 'stale request sent duplicate: %',result;
  end if;
  if jsonb_array_length(public.server_read_thanks_candidates(actor))<>0 then raise exception 'linked request reappeared'; end if;

  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,completion_mode,status,source,created_by,planned_assignee_id,assignment_mode)
  values(h,'manual','お迎え','pickup','evening',today,'whole','todo','test',actor,actor,'person') returning id into task2;
  update public.task_instances set status='completed',completed_at=now(),actual_completed_by_id=partner where id=task2;
  insert into public.requests(household_id,requester_id,recipient_id,shared_title,status,accepted_at,linked_task_instance_id)
  values(h,actor,partner,'お迎え','accepted',now(),task2) returning id into request2;
  perform public.server_tx_send_thanks(actor,gen_random_uuid(),'request',request2,null);
  result:=public.server_tx_send_thanks(actor,gen_random_uuid(),'task',task2,null);
  if result->>'already_sent'<>'true' or (select count(*) from public.user_notifications where household_id=h and type='thanks')<>2 then
    raise exception 'stale task sent duplicate: %',result;
  end if;
  if jsonb_array_length(public.server_read_thanks_candidates(actor))<>0 then raise exception 'linked task reappeared'; end if;
end $$;
rollback;
select 'thanks_linked_dedup: PASS' as result;

\set ON_ERROR_STOP on
begin;
set local role service_role;
do $$
declare
  actor uuid:=gen_random_uuid();
  partner uuid:=gen_random_uuid();
  household uuid;
  token text;
  ride uuid;
  recent_request uuid;
  older_request uuid;
  recent_task uuid;
  today date:=(now() at time zone 'Asia/Tokyo')::date;
  yesterday_start timestamptz:=(today-1)::timestamp at time zone 'Asia/Tokyo';
  candidates jsonb;
begin
  insert into auth.users(id) values(actor),(partner);
  household:=(public.server_tx_create_household(actor,gen_random_uuid(),'Recent thanks','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(actor,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(partner,gen_random_uuid(),token,'B');

  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,completion_mode,status,source,created_by,planned_assignee_id)
    values(household,'manual','お迎え','pickup','evening',today+2,'whole','todo','test',actor,partner)
    returning id into ride;
  insert into public.requests(household_id,requester_id,recipient_id,shared_title,status,accepted_at,assignment_task_instance_id)
    values(household,actor,partner,'お迎え','accepted',yesterday_start,ride) returning id into recent_request;
  insert into public.requests(household_id,requester_id,recipient_id,shared_title,status,accepted_at)
    values(household,actor,partner,'お迎え','accepted',yesterday_start-interval '1 second') returning id into older_request;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,completion_mode,status,source,created_by,planned_assignee_id,completed_at,actual_completed_by_id)
    values(household,'manual','洗濯','household','anytime',today-2,'whole','completed','test',actor,actor,now(),partner)
    returning id into recent_task;

  candidates:=public.server_read_thanks_candidates(actor);
  if jsonb_array_length(candidates)<>2
    or not candidates @> jsonb_build_array(jsonb_build_object('id',recent_request,'target_date',today+2,'activity_date',today-1))
    or not candidates @> jsonb_build_array(jsonb_build_object('id',recent_task,'target_date',today-2,'activity_date',today)) then
    raise exception 'Today candidates, target dates or Japanese date cutoff were wrong: %',candidates;
  end if;
  candidates:=public.server_read_thanks_candidates(actor,today-1);
  if jsonb_array_length(candidates)<>1 or candidates->0->>'id'<>recent_request::text then
    raise exception 'LINE should see exactly the previous local day: %',candidates;
  end if;
  candidates:=public.server_read_thanks_candidates(actor,today-2);
  if jsonb_array_length(candidates)<>1 or candidates->0->>'id'<>older_request::text then
    raise exception 'explicit legacy date changed: %',candidates;
  end if;
  if has_function_privilege('authenticated','public.server_read_thanks_candidates(uuid,date)','execute') then
    raise exception 'thanks RPC was exposed to authenticated clients';
  end if;
end $$;
rollback;
select 'thanks_recent_candidates: PASS' as result;

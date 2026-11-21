create or replace function private.fn_line_preference_column_for_type(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'thanks' then 'request_line'
    when 'request_received' then 'request_line'
    when 'request_accepted' then 'request_line'
    when 'request_declined' then 'request_line'
    when 'handover_created' then 'handover_line'
    when 'request.received' then 'request_line'
    when 'request.checking' then 'request_line'
    when 'request.accepted' then 'request_line'
    when 'request.declined' then 'request_line'
    when 'request.cancelled' then 'request_line'
    when 'request.followup_requested' then 'request_line'
    when 'request.followup_declined' then 'request_line'
    when 'task.completed_neutral' then 'routine_completion_line'
    when 'shopping.handled_neutral' then 'shopping_minor_line'
    when 'shopping.reopened_neutral' then 'shopping_minor_line'
    when 'daily_brief.v2' then 'daily_assignment_line'
    when 'codmon.deadline' then 'routine_checkin_prompt_line'
    else null
  end;
$$;

create table private.sent_thanks (
  household_id uuid not null references public.households(id),
  sender_id uuid not null,
  recipient_id uuid not null,
  source_kind text not null check (source_kind in ('task','request')),
  source_id uuid not null,
  notification_id uuid,
  created_at timestamptz not null default now(),
  primary key(household_id,sender_id,source_kind,source_id),
  foreign key(household_id,sender_id) references public.household_members(household_id,user_id),
  foreign key(household_id,recipient_id) references public.household_members(household_id,user_id)
);
revoke all on private.sent_thanks from public,anon,authenticated;
grant select,insert,update on private.sent_thanks to service_role;

create or replace function public.server_read_thanks_candidates(p_actor_id uuid,p_local_date date default null)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare ctx jsonb; hh uuid; result jsonb;
begin
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id);
  hh:=(ctx->>'household_id')::uuid;
  select coalesce(jsonb_agg(jsonb_build_object('kind',x.kind,'id',x.id,'title',x.title,'recipient_id',x.recipient_id)
    order by x.happened_at desc,x.id),'[]'::jsonb) into result
  from (
    select c.* from (
      select 'task'::text kind,t.id,t.title,
        coalesce(case when t.actual_completed_by_id<>p_actor_id then t.actual_completed_by_id end, performer.real_user_id) recipient_id,
        t.completed_at happened_at
      from public.task_instances t
      left join lateral (
        select a.real_user_id from public.task_actual_participants p
        join public.domain_actor_refs a on a.household_id=p.household_id and a.id=p.actor_ref_id
        where p.household_id=t.household_id and p.task_instance_id=t.id and p.removed_at is null
          and p.test_context_id is null and a.actor_kind='real_user' and a.real_user_id<>p_actor_id
        order by p.recorded_at,a.id limit 1
      ) performer on true
      where t.household_id=hh and t.test_context_id is null and t.status='completed'
        and t.planned_assignee_id=p_actor_id
        and (t.actual_completed_by_id<>p_actor_id or performer.real_user_id is not null)
      union all
      select 'request',r.id,r.shared_title,r.recipient_id,r.accepted_at
      from public.requests r
      where r.household_id=hh and r.test_context_id is null and r.requester_id=p_actor_id
        and r.recipient_id<>p_actor_id and r.status in ('accepted','completed') and r.accepted_at is not null
    ) c
    where (p_local_date is null or (c.happened_at at time zone 'Asia/Tokyo')::date=p_local_date)
      and not exists(select 1 from private.sent_thanks s where s.household_id=hh and s.sender_id=p_actor_id
      and s.source_kind=c.kind and s.source_id=c.id)
    order by c.happened_at desc nulls last,c.id limit 5
  ) x;
  return result;
end $$;

create or replace function public.server_tx_send_thanks(
  p_actor_id uuid,p_operation_id uuid,p_source_kind text,p_source_id uuid,p_note text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  ctx jsonb; claim jsonb; hh uuid; actor_ref uuid; receipt uuid; target_ref uuid; target_user uuid;
  title text; actor_name text; message text; notification uuid; result jsonb;
  note text := nullif(btrim(p_note),'');
begin
  if p_actor_id is null or p_operation_id is null or p_source_id is null
    or p_source_kind is null or p_source_kind not in ('task','request') or length(coalesce(note,''))>300 then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id);
  hh:=(ctx->>'household_id')::uuid; actor_ref:=(ctx->>'actor_ref_id')::uuid;
  claim:=private.fn_claim_canonical_operation_v1(hh,p_actor_id,actor_ref,null,p_operation_id,
    'thanks.send',private.fn_canonical_request_hash_v1(jsonb_build_object('kind',p_source_kind,'id',p_source_id,'note',note)));
  if claim->>'disposition'='replay' then return claim->'result_payload'; end if;
  receipt:=(claim->>'receipt_id')::uuid;

  if p_source_kind='task' then
    select coalesce(case when t.actual_completed_by_id<>p_actor_id then t.actual_completed_by_id end, performer.real_user_id),t.title
    into target_user,title from public.task_instances t
    left join lateral (
      select a.real_user_id from public.task_actual_participants p
      join public.domain_actor_refs a on a.household_id=p.household_id and a.id=p.actor_ref_id
      where p.household_id=t.household_id and p.task_instance_id=t.id and p.removed_at is null
        and p.test_context_id is null and a.actor_kind='real_user' and a.real_user_id<>p_actor_id
      order by p.recorded_at,a.id limit 1
    ) performer on true
    where t.household_id=hh and t.id=p_source_id and t.test_context_id is null
      and t.status='completed' and t.planned_assignee_id=p_actor_id for share of t;
  else
    select r.recipient_id,r.shared_title into target_user,title from public.requests r
    where r.household_id=hh and r.id=p_source_id and r.test_context_id is null
      and r.requester_id=p_actor_id and r.recipient_id<>p_actor_id and r.status in ('accepted','completed')
      and r.accepted_at is not null for share;
  end if;
  if target_user is null then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  select id into target_ref from public.domain_actor_refs
    where household_id=hh and actor_kind='real_user' and real_user_id=target_user;
  if target_ref is null then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;

  insert into private.sent_thanks(household_id,sender_id,recipient_id,source_kind,source_id)
  values(hh,p_actor_id,target_user,p_source_kind,p_source_id)
  on conflict(household_id,sender_id,source_kind,source_id) do nothing;
  if found then
    select coalesce(case m.family_role when 'papa' then 'パパ' when 'mama' then 'ママ' end,p.display_name,'家族')
      into actor_name from public.household_members m left join public.profiles p on p.user_id=m.user_id
      where m.household_id=hh and m.user_id=p_actor_id;
    message:=actor_name||'から：'||title||'、ありがとう。'||coalesce(E'\n'||note,'');
    notification:=private.fn_emit_notification_intent_v1(hh,p_actor_id,actor_ref,null,target_ref,
      'thanks',message,message,jsonb_build_object('source_kind',p_source_kind,'source_id',p_source_id),
      'thanks:'||p_actor_id::text||':'||p_source_kind||':'||p_source_id::text,
      'immediate','normal',null,null,p_source_kind,p_source_id,null);
    update private.sent_thanks set notification_id=notification
      where household_id=hh and sender_id=p_actor_id and source_kind=p_source_kind and source_id=p_source_id;
    result:=jsonb_build_object('sent',true);
  else
    result:=jsonb_build_object('sent',true,'already_sent',true);
  end if;
  perform private.fn_complete_canonical_operation_v1(receipt,p_source_kind,p_source_id,result);
  return result;
end $$;
revoke all on function public.server_read_thanks_candidates(uuid,date) from public,anon,authenticated;
revoke all on function public.server_tx_send_thanks(uuid,uuid,text,uuid,text) from public,anon,authenticated;
grant execute on function public.server_read_thanks_candidates(uuid,date) to service_role;
grant execute on function public.server_tx_send_thanks(uuid,uuid,text,uuid,text) to service_role;

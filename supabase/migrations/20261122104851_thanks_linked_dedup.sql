-- One expression of thanks per linked request and completed task.
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
      -- The same accepted request and its linked completed task are one act.
      and not (c.kind='task' and exists (
        select 1 from public.requests r join private.sent_thanks s
          on s.household_id=r.household_id and s.sender_id=p_actor_id
          and s.source_kind='request' and s.source_id=r.id and s.recipient_id=c.recipient_id
        where r.household_id=hh and r.requester_id=p_actor_id and r.recipient_id=c.recipient_id
          and r.linked_task_instance_id=c.id and r.test_context_id is null
      ))
      and not (c.kind='request' and exists (
        select 1 from public.requests r
        join public.task_instances t on t.household_id=r.household_id and t.id=r.linked_task_instance_id
        where r.household_id=hh and r.id=c.id and r.test_context_id is null and t.test_context_id is null
          and (exists (select 1 from private.sent_thanks s where s.household_id=hh and s.sender_id=p_actor_id
                and s.source_kind='task' and s.source_id=t.id and s.recipient_id=c.recipient_id)
            or (t.status='completed' and t.planned_assignee_id=p_actor_id and
              coalesce(case when t.actual_completed_by_id<>p_actor_id then t.actual_completed_by_id end,
                (select a.real_user_id from public.task_actual_participants p
                 join public.domain_actor_refs a on a.household_id=p.household_id and a.id=p.actor_ref_id
                 where p.household_id=t.household_id and p.task_instance_id=t.id and p.removed_at is null
                   and p.test_context_id is null and a.actor_kind='real_user' and a.real_user_id<>p_actor_id
                 order by p.recorded_at,a.id limit 1))=c.recipient_id))
      ))
    order by c.happened_at desc nulls last,c.id limit 5
  ) x;
  return result;
end $$;

create or replace function public.server_tx_send_thanks(
  p_actor_id uuid,p_operation_id uuid,p_source_kind text,p_source_id uuid,p_note text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  ctx jsonb; claim jsonb; hh uuid; actor_ref uuid; receipt uuid; target_ref uuid; target_user uuid;
  title text; actor_name text; message text; notification uuid; result jsonb; linked_id uuid;
  note text := nullif(btrim(p_note),'');
begin
  if p_actor_id is null or p_operation_id is null or p_source_id is null
    or p_source_kind is null or p_source_kind not in ('task','request') or length(coalesce(note,''))>300 then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id);
  hh:=(ctx->>'household_id')::uuid; actor_ref:=(ctx->>'actor_ref_id')::uuid;
  -- Serialize the actor's sends so simultaneous request/task buttons cannot
  -- both thank the same linked act under different source identifiers.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('thanks:'||hh::text||':'||p_actor_id::text,0));
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
    select r.recipient_id,r.shared_title,r.linked_task_instance_id into target_user,title,linked_id from public.requests r
    where r.household_id=hh and r.id=p_source_id and r.test_context_id is null
      and r.requester_id=p_actor_id and r.recipient_id<>p_actor_id and r.status in ('accepted','completed')
      and r.accepted_at is not null for share;
  end if;
  if target_user is null then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if p_source_kind='task' then
    select r.id into linked_id from public.requests r
    where r.household_id=hh and r.linked_task_instance_id=p_source_id and r.requester_id=p_actor_id
      and r.recipient_id=target_user and r.test_context_id is null;
  end if;
  if linked_id is not null and exists (
    select 1 from private.sent_thanks s where s.household_id=hh and s.sender_id=p_actor_id
      and s.recipient_id=target_user and s.source_id=linked_id
      and s.source_kind=case when p_source_kind='task' then 'request' else 'task' end
  ) then
    result:=jsonb_build_object('sent',true,'already_sent',true);
    perform private.fn_complete_canonical_operation_v1(receipt,p_source_kind,p_source_id,result);
    return result;
  end if;
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

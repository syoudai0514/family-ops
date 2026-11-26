begin;

do $$
declare
  sender uuid := gen_random_uuid();
  receiver uuid := gen_random_uuid();
  outsider uuid := gen_random_uuid();
  household uuid;
  request_id uuid;
  attempt_id uuid;
  initial_attempt_id uuid;
  task jsonb;
  result jsonb;
  operation_id uuid := gen_random_uuid();
  kind text;
begin
  insert into auth.users(id, email) values
    (sender, sender::text || '@example.test'), (receiver, receiver::text || '@example.test'),
    (outsider, outsider::text || '@example.test');
  perform public.server_tx_create_household(sender, gen_random_uuid(), 'Close consultation', 'Sender');
  perform public.server_tx_create_household(outsider, gen_random_uuid(), 'Outside', 'Outside');
  select household_id into strict household from public.household_members where user_id = sender;
  insert into public.household_members (household_id,user_id,member_role) values (household,receiver,'adult');
  perform private.backfill_canonical_foundation_v1();

  result := public.server_tx_send_request_v2(sender, gen_random_uuid(), receiver,
    'お迎え', '頼める？', now() + interval '2 days', now() + interval '1 day');
  request_id := (result->>'request_id')::uuid;
  attempt_id := (result->>'attempt_id')::uuid;
  perform public.server_tx_transition_request_v2(receiver,gen_random_uuid(),request_id,attempt_id,'consult',null,1,1,'line');
  perform public.server_tx_transition_request_v2(receiver,gen_random_uuid(),request_id,attempt_id,'confirm_terms',null,2,1,'pwa');

  begin
    perform public.server_tx_transition_request_v2(sender,gen_random_uuid(),request_id,attempt_id,'decline_consultation',null,3,1,'pwa');
    raise exception 'FAIL sender cannot decline an initial request';
  exception when others then if sqlerrm <> 'REQUEST_TRANSITION_INVALID' then raise; end if;
  end;
  begin
    perform public.server_tx_transition_request_v2(outsider,gen_random_uuid(),request_id,attempt_id,'decline_consultation',null,3,1,'line');
    raise exception 'FAIL outside household closed consultation';
  exception when others then if sqlerrm <> 'REQUEST_NOT_FOUND' then raise; end if;
  end;
  begin
    perform public.server_tx_transition_request_v2(receiver,gen_random_uuid(),request_id,attempt_id,'decline',null,3,1,'line');
    raise exception 'FAIL old decline button closed consultation';
  exception when others then if sqlerrm <> 'REQUEST_TRANSITION_INVALID' then raise; end if;
  end;
  begin
    perform public.server_tx_transition_request_v2(receiver,gen_random_uuid(),request_id,attempt_id,'decline_consultation',null,2,1,'line');
    raise exception 'FAIL stale button closed consultation';
  exception when others then if sqlerrm <> 'REQUEST_ATTEMPT_STALE' then raise; end if;
  end;
  begin
    perform public.server_tx_transition_request_v2(receiver,gen_random_uuid(),request_id,attempt_id,'decline_consultation',null,3,2,'line');
    raise exception 'FAIL stale terms closed consultation';
  exception when others then if sqlerrm <> 'REQUEST_TERMS_REVISION_STALE' then raise; end if;
  end;

  result := public.server_tx_transition_request_v2(receiver,operation_id,request_id,attempt_id,'decline_consultation',null,3,1,'line');
  if result->>'state' <> 'declined' or result->>'attempt_kind' <> 'initial' or
    result is distinct from public.server_tx_transition_request_v2(receiver,operation_id,request_id,attempt_id,'decline_consultation',null,3,1,'line') or
    (select count(*) from public.user_notifications n where n.aggregate_id=request_id and n.type='request.declined' and n.recipient_user_id=sender) <> 1 or
    (select status from public.requests where id=request_id) <> 'declined' then
    raise exception 'FAIL initial consultation decline receipt, projection or notification';
  end if;

  result := public.server_tx_send_request_v2(sender,gen_random_uuid(),receiver,'牛乳','帰りに牛乳を買ってきて',now()+interval '2 days',now()+interval '1 day');
  request_id := (result->>'request_id')::uuid;
  initial_attempt_id := (result->>'attempt_id')::uuid;
  perform public.server_tx_transition_request_v2(receiver,gen_random_uuid(),request_id,initial_attempt_id,'accept',null,1,1,'pwa');
  select to_jsonb(t) into strict task from public.task_instances t join public.requests r on t.id=r.linked_task_instance_id where r.id=request_id;

  foreach kind in array array['change','cancel'] loop
    result := public.server_tx_start_request_followup(sender,gen_random_uuid(),request_id,kind,
      case when kind='change' then '{"title":"豆乳"}'::jsonb end,null,now()+interval '1 day',
      (select revision from public.requests where id=request_id),(task->>'revision')::bigint);
    attempt_id := (result->>'attempt_id')::uuid;
    -- Timestamps in fixture code use transaction time. Give the follow-up a distinct order.
    update public.request_attempts set created_at=clock_timestamp() where id=attempt_id;
    begin
      perform public.server_tx_transition_request_v2(sender,gen_random_uuid(),request_id,attempt_id,'decline_consultation',null,1,1,'pwa');
      raise exception 'FAIL proposer declined their own proposal';
    exception when others then if sqlerrm <> 'REQUEST_TRANSITION_INVALID' then raise; end if;
    end;
    result := public.server_tx_transition_request_v2(receiver,gen_random_uuid(),request_id,attempt_id,'decline_consultation',null,1,1,'pwa');
    if result->>'state' <> 'declined' or result->>'attempt_kind' <> kind or
      (select status from public.requests where id=request_id) <> 'accepted' or
      (select to_jsonb(t) from public.task_instances t where t.id=(task->>'id')::uuid) is distinct from task or
      not exists(select 1 from public.user_notifications n where n.aggregate_id=request_id and n.type='request.followup_declined'
        and n.recipient_user_id=sender and n.payload->>'attempt_id'=attempt_id::text) then
      raise exception 'FAIL declining % changed the accepted task or missed notification',kind;
    end if;
  end loop;

  result := public.server_tx_send_request_v2(sender,gen_random_uuid(),receiver,'送り','送りのお願い',now()+interval '2 days',now()+interval '1 day');
  request_id := (result->>'request_id')::uuid;
  attempt_id := (result->>'attempt_id')::uuid;
  perform public.server_tx_transition_request_v2(receiver,gen_random_uuid(),request_id,attempt_id,'consult',null,1,1,'line');
  update public.request_attempts set reply_due_at=now()-interval '1 minute' where id=attempt_id;
  result := public.server_tx_transition_request_v2(receiver,gen_random_uuid(),request_id,attempt_id,'decline_consultation',null,2,1,'line');
  if result->>'state' <> 'expired' or exists (select 1 from public.user_notifications n where n.aggregate_id=request_id and n.type='request.declined') then
    raise exception 'FAIL expired consultation treated as a decline';
  end if;
end
$$;
rollback;

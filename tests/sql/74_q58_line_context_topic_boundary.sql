-- Appendix A Q58: ordinary colloquial continuation survives a day boundary;
-- explicit topic switch resets; long gap resets only with clearly distinct topic.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid:=gen_random_uuid();
  v_hh uuid;
  v_line text:='U-q58-'||replace(gen_random_uuid()::text,'-','');
  v_pending uuid;
  v_result jsonb;
  v_webhook uuid;
begin
  insert into auth.users(id) values(v_owner);
  insert into public.profiles(user_id,display_name) values(v_owner,'Q58 owner');
  v_hh:=(public.server_tx_create_household(v_owner,gen_random_uuid(),'Q58 household','Asia/Tokyo')->>'household_id')::uuid;
  insert into private.line_user_links(household_id,user_id,line_user_id,status)
  values(v_hh,v_owner,v_line,'active');

  insert into private.pending_actions(
    household_id,actor_id,source,action_type,normalized_payload,operation_id,status,expires_at
  ) values(
    v_hh,v_owner,'line','task_create_once',jsonb_build_object('title','遠足の準備'),gen_random_uuid(),'draft',now()-interval '1 hour'
  ) returning id into v_pending;
  -- Simulate the previous conversation having happened yesterday. The draft is
  -- now expired for mutation safety, but Q58 context/referent must still exist.
  update private.pending_actions set updated_at=now()-interval '26 hours' where id=v_pending;

  insert into private.webhook_inbox(
    provider,provider_event_id,source_external_user_id,payload,status,attempts,last_started_at,lease_owner,lease_token,lease_until
  ) values(
    'line','q58-referent-'||gen_random_uuid(),v_line,
    jsonb_build_object('type','message','message',jsonb_build_object('type','text','text','それ？')),
    'processing',1,now(),'q58',gen_random_uuid(),now()+interval '1 minute'
  ) returning id into v_webhook;
  v_result:=public.server_tx_get_line_conversation_pending(v_owner,v_line);
  if v_result is null or v_result->>'id'<>v_pending::text or v_result->>'status'<>'expired' then
    raise exception 'FAIL Q58: next-day referent lost context: %',v_result;
  end if;

  update private.webhook_inbox set status='done',processed_at=now() where id=v_webhook;
  insert into private.webhook_inbox(
    provider,provider_event_id,source_external_user_id,payload,status,attempts,last_started_at,lease_owner,lease_token,lease_until
  ) values(
    'line','q58-switch-'||gen_random_uuid(),v_line,
    jsonb_build_object('type','message','message',jsonb_build_object('type','text','text','話変わるけど、明日にして')),
    'processing',1,now(),'q58',gen_random_uuid(),now()+interval '1 minute'
  ) returning id into v_webhook;
  if public.server_tx_get_line_conversation_pending(v_owner,v_line) is not null then
    raise exception 'FAIL Q58: explicit topic switch kept prior referent';
  end if;

  update private.webhook_inbox set status='done',processed_at=now() where id=v_webhook;
  insert into private.webhook_inbox(
    provider,provider_event_id,source_external_user_id,payload,status,attempts,last_started_at,lease_owner,lease_token,lease_until
  ) values(
    'line','q58-distinct-'||gen_random_uuid(),v_line,
    jsonb_build_object('type','message','message',jsonb_build_object('type','text','text','買い物を追加したい')),
    'processing',1,now(),'q58',gen_random_uuid(),now()+interval '1 minute'
  ) returning id into v_webhook;
  if public.server_tx_get_line_conversation_pending(v_owner,v_line) is not null then
    raise exception 'FAIL Q58: long-gap clearly distinct topic kept prior referent';
  end if;

  update private.webhook_inbox set status='done',processed_at=now() where id=v_webhook;
  -- Elapsed time alone is still insufficient: ambiguous ordinary prose remains
  -- associated rather than being guessed as a new topic.
  insert into private.webhook_inbox(
    provider,provider_event_id,source_external_user_id,payload,status,attempts,last_started_at,lease_owner,lease_token,lease_until
  ) values(
    'line','q58-ambiguous-'||gen_random_uuid(),v_line,
    jsonb_build_object('type','message','message',jsonb_build_object('type','text','text','どうなった？')),
    'processing',1,now(),'q58',gen_random_uuid(),now()+interval '1 minute'
  );
  v_result:=public.server_tx_get_line_conversation_pending(v_owner,v_line);
  if v_result is null or v_result->>'id'<>v_pending::text then
    raise exception 'FAIL Q58: elapsed time alone reset context';
  end if;
end;
$$;
reset role;
select '74_q58_line_context_topic_boundary: PASS' as result;

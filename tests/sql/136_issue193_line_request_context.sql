-- Actor-bound selection is temporary UI state; canonical requests stay authoritative.
\set ON_ERROR_STOP on
begin;
set local role service_role;
do $$
declare
  papa uuid:=gen_random_uuid(); mama uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  hh uuid; other_hh uuid; request_id uuid; attempt_id uuid; second_id uuid; second_attempt uuid;
  reply jsonb; scope jsonb; selected jsonb; original_due timestamptz; op uuid:=gen_random_uuid();
  before_notices bigint; before_outbox bigint;
  tied_attempt uuid:=gen_random_uuid(); expiry_op uuid:=gen_random_uuid();
begin
  insert into auth.users(id) values(papa),(mama),(outsider);
  hh:=(public.server_tx_create_household(papa,gen_random_uuid(),'LINE selection','Dad')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role) values(hh,mama,'adult');
  other_hh:=(public.server_tx_create_household(outsider,gen_random_uuid(),'Other selection','Other')->>'household_id')::uuid;
  insert into private.line_user_links(household_id,user_id,line_user_id) values
    (hh,papa,'selection-papa-'||papa),(hh,mama,'selection-mama-'||mama),
    (other_hh,outsider,'selection-outsider-'||outsider);
  perform private.backfill_canonical_foundation_v1();
  reply:=public.server_tx_send_request_v2(papa,gen_random_uuid(),mama,'一件目','一件目をお願い',now()+interval '2 days',now()+interval '1 day');
  request_id:=(reply->>'request_id')::uuid; attempt_id:=(reply->>'attempt_id')::uuid;
  reply:=public.server_tx_send_request_v2(papa,gen_random_uuid(),mama,'二件目','二件目をお願い',now()+interval '3 days',now()+interval '1 day');
  second_id:=(reply->>'request_id')::uuid; second_attempt:=(reply->>'attempt_id')::uuid;
  scope:=jsonb_build_object('request_id',second_id,'attempt_id',second_attempt,'revision',1,'terms_revision',1);
  select due_at into original_due from public.requests where id=second_id;
  selected:=public.server_tx_line_request_context(mama,'set',scope);
  if selected->>'request_id'<>second_id::text or selected->>'attempt_id'<>second_attempt::text
    or (selected->>'expires_at')::timestamptz not between clock_timestamp()+interval '14 minutes' and clock_timestamp()+interval '16 minutes'
    or public.server_tx_line_request_context(mama,'get')->>'request_id'<>second_id::text
    or public.server_tx_line_request_context(papa,'get') is not null
    or (select due_at from public.requests where id=second_id) is distinct from original_due then
    raise exception 'FAIL request context: selection scope/ttl/isolation or changed business state'; end if;
  begin
    perform public.server_tx_line_request_context(outsider,'set',scope);
    raise exception 'FAIL request context: outsider selected another household request';
  exception when others then if sqlerrm<>'REQUEST_ATTEMPT_STALE' then raise; end if; end;
  begin
    perform public.server_tx_line_request_context(mama,'set',scope||jsonb_build_object('attempt_id',attempt_id));
    raise exception 'FAIL request context: request and attempt mismatch accepted';
  exception when others then if sqlerrm<>'REQUEST_ATTEMPT_STALE' then raise; end if; end;
  begin
    perform public.server_tx_line_request_context(mama,'set',scope||jsonb_build_object('revision',42));
    raise exception 'FAIL request context: stale revision accepted';
  exception when others then if sqlerrm<>'REQUEST_ATTEMPT_STALE' then raise; end if; end;
  insert into public.request_attempts(id,household_id,request_id,attempt_kind,state,created_by_actor_ref_id,created_at,expired_at)
    select tied_attempt,a.household_id,a.request_id,'reproposal','expired',a.created_by_actor_ref_id,a.created_at,now()
    from public.request_attempts a where a.id=second_attempt;
  begin
    perform public.server_tx_line_request_context(mama,'set',scope);
    raise exception 'FAIL request context: ambiguous latest attempt authorized';
  exception when others then if sqlerrm<>'REQUEST_ATTEMPT_STALE' then raise; end if; end;
  delete from public.request_attempts where id=tied_attempt;
  perform public.server_tx_line_request_context(mama,'clear');
  if public.server_tx_line_request_context(mama,'get') is not null then raise exception 'FAIL request context: clear retained scope'; end if;
  perform public.server_tx_line_request_context(mama,'set',scope);
  update private.line_user_links set request_context=request_context||jsonb_build_object('expires_at',clock_timestamp()-interval '1 second') where user_id=mama;
  if public.server_tx_line_request_context(mama,'get')->>'expired'<>'true' then raise exception 'FAIL request context: expired selection active'; end if;
  perform public.server_tx_line_request_context(mama,'set',scope);
  update private.line_user_links set linked_at=clock_timestamp()+interval '1 second' where user_id=mama;
  if public.server_tx_line_request_context(mama,'get')->>'expired'<>'true' then raise exception 'FAIL request context: relink revived old selection'; end if;
  update private.line_user_links set linked_at=now() where user_id=mama;
  update private.line_user_links set status='unlinked',unlinked_at=now() where user_id=outsider;
  begin
    perform public.server_tx_line_request_context(outsider,'get');
    raise exception 'FAIL request context: unlinked actor read context';
  exception when others then if sqlerrm<>'LINE_LINK_NOT_ACTIVE' then raise; end if; end;

  -- A comment-decline is one canonical decision and one existing notification.
  select count(*) into before_notices from public.user_notifications where household_id=hh and type='request.declined';
  select count(*) into before_outbox from private.notification_outbox where household_id=hh and type='request.declined';
  reply:=public.server_tx_line_decline_request_comment(mama,op,second_id,second_attempt,'今日は間に合いません',1,1);
  if reply->>'state'<>'declined'
    or (select terms->>'decline_comment' from public.request_attempts where id=second_attempt)<>'今日は間に合いません'
    or (select state from public.request_attempts where id=attempt_id)<>'pending'
    or (select due_at from public.requests where id=second_id) is distinct from original_due
    or (select count(*) from public.user_notifications where household_id=hh and type='request.declined')<>before_notices+1 then
    raise exception 'FAIL request comment: canonical decision/comment/other-request isolation'; end if;
  if not exists(select 1 from public.user_notifications where household_id=hh and type='request.declined'
    and payload->>'attempt_id'=second_attempt::text and body like '%今日は間に合いません%') then
    raise exception 'FAIL request comment: existing notification lost comment'; end if;
  if not exists(select 1 from private.notification_outbox o cross join lateral jsonb_array_elements(o.payload->'items') item
    where o.household_id=hh and o.type='request.declined' and item->'payload'->>'attempt_id'=second_attempt::text
      and item->>'body' like '%今日は間に合いません%') or exists(
    select 1 from private.notification_outbox o cross join lateral jsonb_array_elements(o.payload->'items') item
    where o.household_id=hh and o.type='request.declined' and item->'payload'->>'attempt_id'=second_attempt::text
      and item->>'body' not like '%今日は間に合いません%') then
    raise exception 'FAIL request comment: outbox dropped comment'; end if;
  if (select count(*) from private.notification_outbox where household_id=hh and type='request.declined')>before_outbox+1 then
    raise exception 'FAIL request comment: extra notification created'; end if;
  if public.server_tx_line_decline_request_comment(mama,op,second_id,second_attempt,'今日は間に合いません',1,1) is distinct from reply then
    raise exception 'FAIL request comment: replay changed result'; end if;
  begin
    perform public.server_tx_line_decline_request_comment(mama,op,second_id,second_attempt,'別のコメント',1,1);
    raise exception 'FAIL request comment: changed replay payload accepted';
  exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if; end;
  if (select count(*) from public.user_notifications where household_id=hh and type='request.declined')<>before_notices+1 then
    raise exception 'FAIL request comment: replay notified twice'; end if;
  begin
    perform public.server_tx_line_decline_request_comment(outsider,gen_random_uuid(),request_id,attempt_id,'横取り',1,1);
    raise exception 'FAIL request comment: outsider declined';
  exception when others then if sqlerrm not in ('REQUEST_NOT_FOUND','CROSS_HOUSEHOLD_RESOURCE') then raise; end if; end;
  -- A deadline crossed after preview is canonical expiry, never a comment decline.
  update public.request_attempts set reply_due_at=now()-interval '1 second' where id=attempt_id;
  reply:=public.server_tx_line_decline_request_comment(mama,expiry_op,request_id,attempt_id,'期限をまたいだ返答',1,1);
  if reply->>'state'<>'expired' or reply->>'code'<>'REQUEST_ATTEMPT_EXPIRED'
    or (select terms ? 'decline_comment' from public.request_attempts where id=attempt_id)
    or (select count(*) from public.user_notifications where household_id=hh and type='request.declined')<>before_notices+1
    or public.server_tx_line_decline_request_comment(mama,expiry_op,request_id,attempt_id,'期限をまたいだ返答',1,1) is distinct from reply then
    raise exception 'FAIL request comment: expiry was enriched/notified/claimed as decline'; end if;
  if has_function_privilege('anon','public.server_tx_line_request_context(uuid,text,jsonb)','execute')
    or has_function_privilege('authenticated','public.server_tx_line_request_context(uuid,text,jsonb)','execute')
    or has_function_privilege('anon','public.server_tx_line_decline_request_comment(uuid,uuid,uuid,uuid,text,bigint,integer)','execute')
    or has_function_privilege('authenticated','public.server_tx_line_decline_request_comment(uuid,uuid,uuid,uuid,text,bigint,integer)','execute') then
    raise exception 'FAIL request context: service RPC exposed to browser roles'; end if;
end $$;
rollback;

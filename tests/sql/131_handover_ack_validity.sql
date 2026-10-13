\set ON_ERROR_STOP on
begin;
set local role service_role;
do $$
declare
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  h uuid; other_h uuid; ar uuid; br uuid; note uuid; expired uuid; future_note uuid;
  own_note uuid; legacy_own uuid; normal_note uuid; ctx uuid; simulated_note uuid;
  op uuid:=gen_random_uuid(); result jsonb; rejected_op uuid;
  pwa_note uuid; pwa_op uuid:=gen_random_uuid(); pwa_result jsonb;
  ordinary_own uuid;
begin
  insert into auth.users(id) values(a),(b),(outsider);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'Ack validity','Author')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role) values(h,b,'adult');
  other_h:=(public.server_tx_create_household(outsider,gen_random_uuid(),'Other','Other')->>'household_id')::uuid;
  select id into ar from public.domain_actor_refs where household_id=h and real_user_id=a;
  select id into br from public.domain_actor_refs where household_id=h and real_user_id=b;
  insert into public.handovers(household_id,author_id,author_actor_ref_id,shared_text,period,occurred_on,
    ack_policy,valid_from,valid_until)
  values(h,a,ar,'Current','morning',current_date,'required',now()-interval '1 hour',now()+interval '1 hour') returning id into note;
  result:=public.server_tx_ack_info_v1(b,op,note);
  if result->>'acknowledged'<>'true' or not exists(select 1 from public.info_acknowledgements
    where handover_id=note and actor_ref_id=br and test_context_id is null) then
    raise exception 'FAIL ack validity: current recipient acknowledgement missing'; end if;
  update public.handovers set valid_until=now()-interval '1 minute' where id=note;
  if public.server_tx_ack_info_v1(b,op,note) is distinct from result then
    raise exception 'FAIL ack validity: successful receipt did not replay after expiry'; end if;
  rejected_op:=gen_random_uuid();
  begin
    perform public.server_tx_ack_info_v1(b,rejected_op,note);
    raise exception 'FAIL ack validity: late postback with new operation accepted';
  exception when others then if sqlerrm<>'INFO_ACK_NOT_ACTIONABLE' then raise; end if; end;
  if exists(select 1 from private.canonical_operation_receipts where operation_id=rejected_op) then
    raise exception 'FAIL ack validity: rejected action left a receipt'; end if;
  update public.handovers set status='expired' where id=note;
  if public.server_tx_ack_info_v1(b,op,note) is distinct from result then
    raise exception 'FAIL ack validity: ended-note successful receipt did not replay'; end if;
  begin
    perform public.server_tx_ack_info_v1(outsider,op,note);
    raise exception 'FAIL ack validity: another household replayed receipt';
  exception when others then if sqlerrm<>'INFO_NOT_FOUND' then raise; end if; end;

  insert into public.handovers(household_id,author_id,author_actor_ref_id,shared_text,period,occurred_on,
    ack_policy,valid_from,valid_until)
  values(h,a,ar,'Expired','day',current_date,'required',now()-interval '2 hours',now()-interval '1 hour') returning id into expired;
  insert into public.handovers(household_id,author_id,author_actor_ref_id,shared_text,period,occurred_on,
    ack_policy,valid_from,valid_until)
  values(h,a,ar,'Future','day',current_date,'required',now()+interval '1 hour',null) returning id into future_note;
  insert into public.handovers(household_id,author_id,author_actor_ref_id,shared_text,period,occurred_on,ack_policy)
  values(h,b,br,'Own','day',current_date,'required') returning id into own_note;
  insert into public.handovers(household_id,author_id,shared_text,period,occurred_on,ack_policy)
  values(h,b,'Legacy own','day',current_date,'required') returning id into legacy_own;
  insert into public.handovers(household_id,author_id,author_actor_ref_id,shared_text,period,occurred_on,ack_policy)
  values(h,a,ar,'Ordinary share','day',current_date,'none') returning id into normal_note;
  for rejected_op in select x from unnest(array[expired,future_note,own_note,legacy_own,normal_note]) x loop
    begin
      perform public.server_tx_ack_info_v1(b,gen_random_uuid(),rejected_op);
      raise exception 'FAIL ack validity: non-actionable note acknowledged: %',rejected_op;
    exception when others then if sqlerrm<>'INFO_ACK_NOT_ACTIONABLE' then raise; end if; end;
  end loop;
  for rejected_op in select x from unnest(array[expired,future_note,own_note,legacy_own]) x loop
    begin
      perform public.server_tx_mark_handover_read(b,gen_random_uuid(),rejected_op);
      raise exception 'FAIL ack validity: PWA non-actionable note acknowledged: %',rejected_op;
    exception when others then if sqlerrm<>'INFO_ACK_NOT_ACTIONABLE' then raise; end if; end;
  end loop;
  if exists(select 1 from public.info_acknowledgements
    where handover_id=any(array[expired,future_note,own_note,legacy_own,normal_note])) then
    raise exception 'FAIL ack validity: rejected notes gained acknowledgement'; end if;
  -- An ordinary share can still be dismissed by its recipient in PWA.
  perform public.server_tx_mark_handover_read(b,gen_random_uuid(),normal_note);
  update public.handovers set valid_until=now()-interval '1 minute',valid_from=now()-interval '1 hour',status='expired'
  where id=normal_note;
  perform public.server_tx_mark_handover_read(b,gen_random_uuid(),normal_note);
  insert into public.handovers(household_id,author_id,author_actor_ref_id,shared_text,period,occurred_on,
    ack_policy,visibility,status,valid_from,valid_until)
  values(h,b,br,'My ordinary historical note','day',current_date,'none','self','expired',
    now()-interval '1 hour',now()-interval '1 minute') returning id into ordinary_own;
  perform public.server_tx_mark_handover_read(b,gen_random_uuid(),ordinary_own);
  begin
    perform public.server_tx_mark_handover_read(a,gen_random_uuid(),ordinary_own);
    raise exception 'FAIL ack validity: another recipient read private ordinary note';
  exception when others then if sqlerrm<>'INFO_ACK_NOT_ACTIONABLE' then raise; end if; end;
  if not exists(select 1 from public.handover_reads where handover_id=ordinary_own and user_id=b) then
    raise exception 'FAIL ack validity: ordinary author history read regressed'; end if;
  insert into public.handovers(household_id,author_id,author_actor_ref_id,shared_text,period,occurred_on,
    ack_policy,valid_from,valid_until)
  values(h,a,ar,'PWA current','day',current_date,'required',now()-interval '1 hour',now()+interval '1 hour') returning id into pwa_note;
  pwa_result:=public.server_tx_mark_handover_read(b,pwa_op,pwa_note);
  update public.handovers set valid_until=now()-interval '1 minute',status='expired' where id=pwa_note;
  if public.server_tx_mark_handover_read(b,pwa_op,pwa_note) is distinct from pwa_result then
    raise exception 'FAIL ack validity: PWA successful receipt did not replay after expiry'; end if;
  begin
    perform public.server_tx_mark_handover_read(b,gen_random_uuid(),pwa_note);
    raise exception 'FAIL ack validity: PWA late postback recorded a new read';
  exception when others then if sqlerrm<>'INFO_ACK_NOT_ACTIONABLE' then raise; end if; end;
  begin
    perform public.server_tx_mark_handover_read(outsider,pwa_op,pwa_note);
    raise exception 'FAIL ack validity: PWA cross household replay accepted';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  insert into public.test_simulation_contexts(household_id,operator_user_id) values(h,a) returning id into ctx;
  insert into public.handovers(household_id,author_id,author_actor_ref_id,shared_text,period,occurred_on,ack_policy,test_context_id)
  values(h,a,ar,'Simulation','day',current_date,'required',ctx) returning id into simulated_note;
  begin
    perform public.server_tx_ack_info_v1(b,gen_random_uuid(),simulated_note);
    raise exception 'FAIL ack validity: production action reached test context';
  exception when others then if sqlerrm<>'ACTOR_SCOPE_CONFLICT' then raise; end if; end;
  begin
    perform public.server_tx_mark_handover_read(b,gen_random_uuid(),simulated_note);
    raise exception 'FAIL ack validity: PWA production read reached test context';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  begin
    perform public.server_tx_ack_info_v1(b,op,expired);
    raise exception 'FAIL ack validity: same operation accepted different target';
  exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if; end;
end;
$$;
reset role;
do $$ begin
  if has_function_privilege('authenticated','public.server_tx_ack_info_v1(uuid,uuid,uuid)','execute')
    or has_function_privilege('anon','public.server_tx_ack_info_v1(uuid,uuid,uuid)','execute') then
    raise exception 'FAIL ack validity: service-only adapter exposed'; end if;
end; $$;
rollback;
select 'handover_ack_validity: PASS' as result;

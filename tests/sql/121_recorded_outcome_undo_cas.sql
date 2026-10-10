\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  u1 uuid:=gen_random_uuid(); u2 uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  hh uuid; t uuid; op uuid:=gen_random_uuid(); undo_op uuid:=gen_random_uuid();
  saved jsonb; restored jsonb; legacy_result jsonb; rev bigint; legacy_op uuid:=gen_random_uuid();
begin
  insert into auth.users(id) values(u1),(u2),(outsider);
  hh:=(public.server_tx_create_household(u1,gen_random_uuid(),'Undo family','Owner')->>'household_id')::uuid;
  perform public.server_tx_create_household(outsider,gen_random_uuid(),'Other family','Other');
  insert into public.household_members(household_id,user_id,member_role) values(hh,u2,'adult');
  t:=(public.server_tx_create_task(u1,gen_random_uuid(),'記録の取り消し','chore','2026-10-12',null,u1,'whole','anytime',null)->>'task_id')::uuid;
  select revision into rev from public.task_instances where id=t;
  saved:=public.server_tx_mark_task_could_not_do_v1(u1,op,t,false,'pwa',rev);
  if saved is distinct from public.server_tx_mark_task_could_not_do_v1(u1,op,t,false,'pwa',rev)
    or (select count(*) from public.task_events where task_instance_id=t and event_type='skipped')<>1 then
    raise exception 'FAIL: recording retry duplicated events'; end if;
  begin
    perform public.server_tx_mark_task_could_not_do_v1(u1,op,t,false,'pwa',rev+1);
    raise exception 'FAIL: different retry accepted';
  exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if; end;
  restored:=public.server_tx_mark_task_could_not_do_v1(u1,undo_op,t,true,'pwa',(saved->>'revision')::bigint);
  if restored->>'status'<>'todo'
    or restored is distinct from public.server_tx_mark_task_could_not_do_v1(u1,undo_op,t,true,'pwa',(saved->>'revision')::bigint)
    or (select count(*) from public.task_events where task_instance_id=t and event_type='could_not_do_reverted')<>1 then
    raise exception 'FAIL: undo replay failed'; end if;
  -- An older client can record a later result; the first toast must not erase it.
  legacy_result:=public.server_tx_mark_task_could_not_do_v1(u2,legacy_op,t,false,'pwa');
  if not exists(select 1 from private.mutation_receipts where actor_id=u2 and operation_id=legacy_op
    and action_type='task-could-not-do' and request_hash=encode(sha256(convert_to(
      'task-could-not-do|'||t::text||'|false|pwa','UTF8')),'hex')) then
    raise exception 'FAIL: legacy receipt format changed'; end if;
  -- A receipt from before the upgrade can still be replayed through the adapter.
  legacy_op:=gen_random_uuid();
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash,actor_ref_id,result_type,result_id,result_payload)
    values(u2,legacy_op,'task-could-not-do',encode(sha256(convert_to(
      'task-could-not-do|'||t::text||'|false|pwa','UTF8')),'hex'),
      (private.fn_require_production_actor_context_v1(u2)->>'actor_ref_id')::uuid,'task_instance',t,legacy_result);
  if legacy_result is distinct from public.server_tx_mark_task_could_not_do_v1(u2,legacy_op,t,false,'pwa') then
    raise exception 'FAIL: pre-upgrade receipt did not replay'; end if;
  if restored is distinct from public.server_tx_mark_task_could_not_do_v1(u1,undo_op,t,true,'pwa',(saved->>'revision')::bigint) then
    raise exception 'FAIL: response-lost undo replay depends on later partner result'; end if;
  begin
    perform public.server_tx_mark_task_could_not_do_v1(u1,gen_random_uuid(),t,true,'pwa',(saved->>'revision')::bigint);
    raise exception 'FAIL: stale undo erased partner record';
  exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  if (select status from public.task_instances where id=t)<>'skipped' then
    raise exception 'FAIL: conflict modified current state'; end if;
  select revision into rev from public.task_instances where id=t;
  begin
    perform public.server_tx_mark_task_could_not_do_v1(outsider,gen_random_uuid(),t,true,'pwa',rev);
    raise exception 'FAIL: foreign outcome modified';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  if has_function_privilege('authenticated','public.server_tx_mark_task_could_not_do_v1(uuid,uuid,uuid,boolean,text,bigint)','execute')
    or has_function_privilege('anon','public.server_tx_mark_task_could_not_do_v1(uuid,uuid,uuid,boolean,text,bigint)','execute') then
    raise exception 'FAIL: actor adapter exposed to browser'; end if;
end $$;
reset role;
rollback;
select 'recorded_outcome_undo_cas: PASS' as result;

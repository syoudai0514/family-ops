\set ON_ERROR_STOP on
begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid; token text; op uuid:=gen_random_uuid(); actor_ref uuid;
  start_at timestamptz:=date_trunc('day',now() at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo';
  operation jsonb; rejected boolean:=false;
begin
  insert into auth.users(id) values(a),(b);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'quiet activity','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  delete from private.mutation_receipts where actor_id in (a,b);
  if not private.fn_recipient_quiet_mode_v1(h,a,start_at+interval '8 hours') then raise exception 'inactive auto was not quiet'; end if;
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash,created_at)
    values(a,op,'complete-task','test',start_at-interval '1 day');
  if not private.fn_recipient_quiet_mode_v1(h,a,start_at+interval '8 hours') then raise exception 'unfinished mutation counted'; end if;
  update private.mutation_receipts set result_payload='{"ok":true}' where actor_id=a and operation_id=op;
  if private.fn_recipient_quiet_mode_v1(h,a,start_at+interval '8 hours') then raise exception 'own app operation ignored'; end if;
  delete from private.mutation_receipts where actor_id=a and operation_id=op;
  select id into actor_ref from public.domain_actor_refs where household_id=h and real_user_id=a and test_context_id is null;
  insert into private.canonical_operation_receipts(household_id,operator_user_id,actor_ref_id,operation_id,action_type,request_hash,created_at,completed_at)
    values(h,a,actor_ref,gen_random_uuid(),'family_event.provider_transfer','test',start_at-interval '1 day',start_at-interval '1 day');
  if not private.fn_recipient_quiet_mode_v1(h,a,start_at+interval '8 hours') then raise exception 'background provider transfer counted'; end if;
  insert into private.canonical_operation_receipts(household_id,operator_user_id,actor_ref_id,operation_id,action_type,request_hash,created_at,completed_at)
    values(h,a,actor_ref,gen_random_uuid(),'shopping.create','test',start_at-interval '1 day',start_at-interval '1 day');
  if private.fn_recipient_quiet_mode_v1(h,a,start_at+interval '8 hours') then raise exception 'shopping action ignored'; end if;
  delete from private.canonical_operation_receipts where household_id=h and operator_user_id=a;
  insert into private.line_user_links(household_id,user_id,line_user_id,linked_at) values(h,b,'quiet-test-'||b,start_at-interval '9 days');
  insert into private.webhook_inbox(provider,provider_event_id,source_external_user_id,payload,received_at)
    values('line','quiet-test-follow-'||b,'quiet-test-'||b,'{"type":"follow"}',start_at-interval '1 day');
  if not private.fn_recipient_quiet_mode_v1(h,b,start_at+interval '8 hours') then raise exception 'follow counted as activity'; end if;
  insert into private.webhook_inbox(provider,provider_event_id,source_external_user_id,payload,received_at)
    values('line','quiet-test-message-'||b,'quiet-test-'||b,'{"type":"message"}',start_at-interval '1 day');
  if private.fn_recipient_quiet_mode_v1(h,b,start_at+interval '8 hours') then raise exception 'own message ignored'; end if;
  if not private.fn_recipient_quiet_mode_v1(h,a,start_at+interval '8 hours') then raise exception 'other member activity counted'; end if;
  update private.webhook_inbox set received_at=start_at where provider_event_id='quiet-test-message-'||b;
  if not private.fn_recipient_quiet_mode_v1(h,b,start_at+interval '8 hours') then raise exception 'today should take effect tomorrow'; end if;
  if private.fn_recipient_quiet_mode_v1(h,b,start_at+interval '1 day 8 hours') then raise exception 'next day did not resume'; end if;
  update private.webhook_inbox set received_at=start_at-interval '8 days' where provider_event_id='quiet-test-message-'||b;
  if not private.fn_recipient_quiet_mode_v1(h,b,start_at+interval '8 hours') then raise exception 'expired activity counted'; end if;
  operation:=public.server_tx_update_reminder_settings(b,op,'{"quiet_mode":"normal"}');
  if operation<>public.server_tx_update_reminder_settings(b,op,'{"quiet_mode":"normal"}') then raise exception 'settings replay changed'; end if;
  if private.fn_recipient_quiet_mode_v1(h,b,start_at+interval '8 hours') then raise exception 'normal override ignored'; end if;
  if (select quiet_mode from public.notification_preferences where household_id=h and user_id=a)<>'auto' then raise exception 'other member preference changed'; end if;
  perform public.server_tx_update_reminder_settings(b,gen_random_uuid(),'{"quiet_mode":"quiet"}');
  insert into private.webhook_inbox(provider,provider_event_id,source_external_user_id,payload,received_at)
    values('line','quiet-test-button-'||b,'quiet-test-'||b,'{"type":"postback"}',start_at-interval '1 day');
  if not private.fn_recipient_quiet_mode_v1(h,b,start_at+interval '8 hours') then raise exception 'quiet override ignored'; end if;
  perform public.server_tx_update_reminder_settings(b,gen_random_uuid(),'{"quiet_mode":"auto"}');
  if private.fn_recipient_quiet_mode_v1(h,b,start_at+interval '8 hours') then raise exception 'postback ignored'; end if;
  begin perform public.server_tx_update_reminder_settings(b,gen_random_uuid(),'{"quiet_mode":"other"}');
  exception when raise_exception then if sqlerrm='INVALID_INPUT' then rejected:=true; else raise; end if; end;
  if not rejected then raise exception 'invalid mode accepted'; end if;
  if has_function_privilege('authenticated','private.fn_recipient_quiet_mode_v1(uuid,uuid,timestamptz)','EXECUTE') then raise exception 'private activity exposed'; end if;
end $$;
rollback;
select 'automatic_quiet_activity: PASS' as result;

\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values ('14400000-0000-0000-0000-000000000001');
set role service_role;
do $$
declare
  actor uuid := '14400000-0000-0000-0000-000000000001';
  household uuid;
  first_id uuid;
  second_id uuid;
  revision bigint;
begin
  household := (public.server_tx_create_household(actor, gen_random_uuid(), 'Photo failure', 'Owner')->>'household_id')::uuid;
  insert into private.line_user_links(household_id,user_id,line_user_id,status) values(household,actor,'LINE-FAILURE','active');
  first_id := (public.server_tx_enqueue_nursery_line_image('evt-fail-1','msg-fail-1','LINE-FAILURE',now()-interval '1 minute')->>'intake_id')::uuid;
  second_id := (public.server_tx_enqueue_nursery_line_image('evt-fail-2','msg-fail-2','LINE-FAILURE',now())->>'intake_id')::uuid;
  perform public.server_tx_claim_nursery_line_images(20,'failure-test');
  select i.revision into revision from private.nursery_line_image_intakes i where i.id=first_id;
  perform public.server_tx_fail_nursery_line_image(first_id,revision,'GEMINI_HTTP_503');
  if (select last_error from private.nursery_line_image_intakes where id=first_id) <> 'GEMINI_HTTP_503' then
    raise exception 'failure code not stored';
  end if;
  if public.server_read_previous_nursery_failure(first_id) or not public.server_read_previous_nursery_failure(second_id) then
    raise exception 'previous failure lookup incorrect';
  end if;
  update private.nursery_line_image_intakes set received_at=now()-interval '25 hours' where id=first_id;
  if public.server_read_previous_nursery_failure(second_id) then raise exception 'expired failure reused'; end if;
  if has_function_privilege('authenticated','public.server_tx_fail_nursery_line_image(uuid,bigint,text)','execute')
    or has_function_privilege('authenticated','public.server_read_previous_nursery_failure(uuid)','execute') then
    raise exception 'private failure context exposed';
  end if;
end $$;
rollback;
select 'nursery_failure_context: PASS' as result;

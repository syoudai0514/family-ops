\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values ('14300000-0000-0000-0000-000000000001'), ('14300000-0000-0000-0000-000000000002');
set role service_role;
do $$
declare
  actor uuid := '14300000-0000-0000-0000-000000000001';
  other uuid := '14300000-0000-0000-0000-000000000002';
  household uuid;
  other_household uuid;
  child uuid;
  context uuid;
  intake uuid;
  result jsonb;
begin
  household := (public.server_tx_create_household(actor, gen_random_uuid(), 'Photo', 'Owner')->>'household_id')::uuid;
  other_household := (public.server_tx_create_household(other, gen_random_uuid(), 'Other', 'Other')->>'household_id')::uuid;
  insert into private.line_user_links(household_id,user_id,line_user_id,status)
  values (household,actor,'LINE-CHILD-1','active'),(other_household,other,'LINE-CHILD-2','active');
  insert into public.family_children(household_id,display_name) values (household,'詩乃') returning id into child;
  insert into public.child_school_contexts(household_id,child_id,school_display_name,effective_from,recognition_aliases)
  values(household,child,'園',current_date - 30,array['しの']) returning id into context;
  intake := (public.server_tx_enqueue_nursery_line_image('evt-child-1','msg-child-1','LINE-CHILD-1',now())->>'intake_id')::uuid;
  update private.nursery_line_image_intakes set status='needs_clarification', ambiguity_fields=array['child'] where id=intake;
  result := public.server_read_line_nursery_child_context(actor,'LINE-CHILD-1');
  if result->>'id' <> intake::text or result#>>'{contexts,0,id}' <> context::text then
    raise exception 'missing pending child context: %', result;
  end if;
  if public.server_read_line_nursery_child_context(other,'LINE-CHILD-1') is not null
    or public.server_read_line_nursery_child_context(actor,'LINE-CHILD-2') is not null then
    raise exception 'cross sender context leaked';
  end if;
  update private.nursery_line_image_intakes set received_at=now()-interval '25 hours' where id=intake;
  if public.server_read_line_nursery_child_context(actor,'LINE-CHILD-1') is not null then
    raise exception 'expired clarification remained active';
  end if;
  update private.nursery_line_image_intakes set received_at=now()-interval '1 minute' where id=intake;
  perform public.server_tx_enqueue_nursery_line_image('evt-child-2','msg-child-2','LINE-CHILD-1',now());
  if public.server_read_line_nursery_child_context(actor,'LINE-CHILD-1') is not null then
    raise exception 'older photo captured reply for newer intake';
  end if;
  if has_function_privilege('authenticated','public.server_read_line_nursery_child_context(uuid,text)','execute') then
    raise exception 'client can read private LINE context';
  end if;
end $$;
rollback;
select 'line_nursery_child_context: PASS' as result;

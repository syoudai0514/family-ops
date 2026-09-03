\set ON_ERROR_STOP on
set role service_role;

do $$
declare v_owner uuid:='10000000-0000-0000-0000-000000000048'; v_context uuid; v_open jsonb; v_workspace jsonb; v_closed jsonb;
begin
  insert into auth.users(id) values(v_owner) on conflict do nothing;
  insert into public.profiles(user_id,display_name) values(v_owner,'DD10 owner') on conflict do nothing;
  perform public.server_tx_create_household(v_owner,'20000000-0000-0000-0000-000000000048','DD10 household','Asia/Tokyo');
  v_open:=public.server_tx_open_test_simulation_v1(v_owner,'20000000-0000-0000-0000-000000000148','mama','一人テスト');
  v_context:=(v_open->>'test_context_id')::uuid;
  if v_open->>'display_label'<>'🧪 ママ' then raise exception 'FAIL DD10: simulation role was not labelled'; end if;
  if exists(select 1 from public.household_members where household_id=(select household_id from public.test_simulation_contexts where id=v_context) and user_id is null)
     or exists(select 1 from public.domain_actor_refs where id=(v_open->>'simulated_actor_ref_id')::uuid and real_user_id is not null) then
    raise exception 'FAIL DD10: simulated actor became real identity'; end if;
  v_workspace:=public.server_tx_get_test_simulation_workspace_v1(v_owner,v_context);
  if v_workspace->>'status'<>'active' or v_workspace->>'display_label'<>'🧪 ママ' then raise exception 'FAIL DD10: test workspace reader leaked/changed identity'; end if;
  begin
    perform public.server_tx_open_test_simulation_v1(v_owner,'20000000-0000-0000-0000-000000000248','mama','duplicate');
    raise exception 'FAIL DD10: second active simulation accepted';
  exception when others then if sqlerrm<>'TEST_SIMULATION_ALREADY_ACTIVE' then raise; end if; end;
  v_closed:=public.server_tx_archive_test_simulation_v1(v_owner,'20000000-0000-0000-0000-000000000348',v_context,1);
  if v_closed->>'status'<>'archived' or v_closed->>'production_conversion'<>'false' then raise exception 'FAIL DD10: archive semantics invalid'; end if;
  if (public.server_tx_get_test_simulation_workspace_v1(v_owner,v_context)->>'status')<>'archived' then raise exception 'FAIL DD10: archived audit workspace unavailable'; end if;
end;
$$;

reset role;
select '48_dd10_one_user_simulation_workspace: PASS' as result;

-- WP-DD1 regression: members created after the one-time deterministic
-- backfill must immediately have a canonical real-user ActorRef.

do $$
declare
  v_owner uuid := '10000000-0000-0000-0000-000000000043';
  v_operation uuid := '20000000-0000-0000-0000-000000000043';
  v_created jsonb;
  v_household uuid;
begin
  insert into auth.users (id, aud, role, email, encrypted_password)
  values (v_owner, 'authenticated', 'authenticated', 'actor-continuity@example.test', '')
  on conflict (id) do nothing;

  insert into public.profiles (user_id, display_name)
  values (v_owner, 'Actor continuity owner')
  on conflict (user_id) do nothing;

  v_created := public.server_tx_create_household(
    v_owner,
    v_operation,
    'Actor continuity household',
    'Asia/Tokyo'
  );
  v_household := (v_created->>'household_id')::uuid;

  if not exists (
    select 1
    from public.domain_actor_refs a
    where a.household_id = v_household
      and a.actor_kind = 'real_user'
      and a.real_user_id = v_owner
      and a.test_context_id is null
  ) then
    raise exception 'FAIL WP-DD1: new household member has no canonical ActorRef';
  end if;

  if (
    select count(*)
    from public.domain_actor_refs a
    where a.household_id = v_household
      and a.actor_kind = 'real_user'
      and a.real_user_id = v_owner
  ) <> 1 then
    raise exception 'FAIL WP-DD1: member ActorRef is not unique';
  end if;
end;
$$;

select 'PASS WP-DD1 member ActorRef continuity' as result;

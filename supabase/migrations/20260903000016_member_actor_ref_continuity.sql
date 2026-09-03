-- WP-DD1 continuity fix: deterministic backfill covers members that existed at
-- migration time; this trigger keeps the invariant true for every later
-- household creation and join. ActorRef remains the canonical identity and
-- the household member row is only its production compatibility source.

create or replace function private.fn_ensure_real_member_actor_ref_v1()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.domain_actor_refs (
    household_id,
    actor_kind,
    real_user_id,
    test_context_id,
    simulated_role
  ) values (
    new.household_id,
    'real_user',
    new.user_id,
    null,
    null
  )
  on conflict (household_id, real_user_id)
    where actor_kind = 'real_user'
  do nothing;

  return new;
end;
$$;

revoke all on function private.fn_ensure_real_member_actor_ref_v1()
  from public, anon, authenticated;
grant execute on function private.fn_ensure_real_member_actor_ref_v1()
  to service_role;

create trigger household_members_ensure_real_actor_ref_v1
  after insert on public.household_members
  for each row execute function private.fn_ensure_real_member_actor_ref_v1();

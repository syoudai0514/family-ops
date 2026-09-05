-- Appendix A Q107-Q109 exact contract:
-- anyone -> self claim -> explicit takeover; only current claimant can release;
-- a claim does not expire merely because time has passed.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_partner uuid := gen_random_uuid();
  v_hh uuid;
  v_owner_ref uuid;
  v_partner_ref uuid;
  v_item uuid;
  v_revision bigint;
  v_result jsonb;
  v_failed boolean;
begin
  insert into auth.users(id) values (v_owner),(v_partner);
  insert into public.profiles(user_id,display_name) values
    (v_owner,'Shopping owner'),(v_partner,'Shopping partner');

  v_hh := (public.server_tx_create_household(
    v_owner,gen_random_uuid(),'Shopping anyone lifecycle','Asia/Tokyo'
  )->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role,family_role)
  values(v_hh,v_partner,'adult','mama');

  select id into v_owner_ref from public.domain_actor_refs
    where household_id=v_hh and actor_kind='real_user' and real_user_id=v_owner;
  select id into v_partner_ref from public.domain_actor_refs
    where household_id=v_hh and actor_kind='real_user' and real_user_id=v_partner;

  v_result := public.server_tx_add_shopping_item_v2(
    v_owner,gen_random_uuid(),'牛乳','store','anyone',null,
    'avoid_duplicate',null,null
  );
  v_item := (v_result->>'shopping_item_id')::uuid;
  v_revision := (v_result->>'revision')::bigint;

  -- Q107: "誰でもOK" is represented by no active claimant until somebody opts in.
  if exists(
    select 1 from public.shopping_items
    where id=v_item and active_claimant_actor_ref_id is not null
  ) then raise exception 'FAIL Q107: anyone item was pre-claimed'; end if;

  -- Q108: the actual shopper claims explicitly with "自分がやる".
  v_result := public.server_tx_shopping_claim_v2(
    v_owner,gen_random_uuid(),v_item,'claim',v_revision
  );
  v_revision := (v_result->>'revision')::bigint;
  if (select active_claimant_actor_ref_id from public.shopping_items where id=v_item)
     is distinct from v_owner_ref then
    raise exception 'FAIL Q108: self claim did not become active claimant';
  end if;

  -- Q109: another household adult cannot release somebody else's claim.
  v_failed := false;
  begin
    perform public.server_tx_shopping_claim_v2(
      v_partner,gen_random_uuid(),v_item,'release',v_revision
    );
  exception when others then
    v_failed := position('SHOPPING_CLAIM_NOT_OWNED' in sqlerrm)>0;
  end;
  if not v_failed then
    raise exception 'FAIL Q109: non-claimant was able to release claim';
  end if;

  -- Age the claim far beyond any reasonable lease. There is intentionally no
  -- expiry/TTL semantics: merely becoming old must not clear ownership.
  update public.shopping_items
     set claimed_at=now()-interval '365 days'
   where id=v_item;
  select revision into v_revision from public.shopping_items where id=v_item;
  if (select active_claimant_actor_ref_id from public.shopping_items where id=v_item)
     is distinct from v_owner_ref then
    raise exception 'FAIL Q109: aged claim auto-released';
  end if;

  -- Q108: necessary hand-off is an explicit takeover by the other adult.
  v_result := public.server_tx_shopping_claim_v2(
    v_partner,gen_random_uuid(),v_item,'takeover',v_revision
  );
  v_revision := (v_result->>'revision')::bigint;
  if (select active_claimant_actor_ref_id from public.shopping_items where id=v_item)
     is distinct from v_partner_ref then
    raise exception 'FAIL Q108: takeover did not replace claimant';
  end if;

  -- The old claimant still cannot release after takeover.
  v_failed := false;
  begin
    perform public.server_tx_shopping_claim_v2(
      v_owner,gen_random_uuid(),v_item,'release',v_revision
    );
  exception when others then
    v_failed := position('SHOPPING_CLAIM_NOT_OWNED' in sqlerrm)>0;
  end;
  if not v_failed then
    raise exception 'FAIL Q109: previous claimant released current claim';
  end if;

  -- Only the current claimant can manually release it.
  v_result := public.server_tx_shopping_claim_v2(
    v_partner,gen_random_uuid(),v_item,'release',v_revision
  );
  if exists(
    select 1 from public.shopping_items
    where id=v_item and (active_claimant_actor_ref_id is not null or claimed_at is not null)
  ) then raise exception 'FAIL Q109: claimant release did not clear active claim'; end if;
end;
$$;
reset role;
select '71_shopping_anyone_claim_lifecycle: PASS' as result;

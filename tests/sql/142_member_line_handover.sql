\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid();
  h uuid; token text; result jsonb; raw text; old_raw text; rejected boolean;
begin
  insert into auth.users(id) values(u1),(u2),(u3);
  h := (public.server_tx_create_household(u1,gen_random_uuid(),'Seat H','Papa')->>'household_id')::uuid;
  token := public.server_tx_create_household_invite(u1,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(u2,gen_random_uuid(),token,'ママ（仮）');
  perform public.server_tx_create_household(u3,gen_random_uuid(),'Other H','Other');

  -- The stand-in's LINE is linked (the usual 10-minute self code).
  raw := public.server_tx_create_line_link_token(u2,gen_random_uuid())->>'raw_token';
  perform public.server_tx_claim_line_link_token('Ustandin0000000000000000000000000', raw);
  insert into private.line_conversation_turns(household_id,actor_id,role,text) values(h,u2,'user','test');

  -- A linked seat cannot get a new code.
  rejected := false;
  begin perform public.server_tx_create_member_line_link_token(u1,gen_random_uuid(),u2);
  exception when others then rejected := sqlerrm='MEMBER_LINE_ALREADY_LINKED'; end;
  if not rejected then raise exception 'FAIL code issued for a linked seat'; end if;

  -- Only the other adult of the same household.
  rejected := false;
  begin perform public.server_tx_release_member_line(u3,gen_random_uuid(),u2);
  exception when others then rejected := sqlerrm='CROSS_HOUSEHOLD_RESOURCE'; end;
  if not rejected then raise exception 'FAIL other household released the seat'; end if;
  rejected := false;
  begin perform public.server_tx_release_member_line(u1,gen_random_uuid(),u1);
  exception when others then rejected := sqlerrm='INVALID_INPUT'; end;
  if not rejected then raise exception 'FAIL released own LINE'; end if;

  -- Release: the link, its LINE id and the stand-in's conversation are gone; the seat stays.
  result := public.server_tx_release_member_line(u1,gen_random_uuid(),u2);
  if not (result->>'released')::boolean then raise exception 'FAIL release result %', result; end if;
  if exists(select 1 from private.line_user_links where user_id=u2) then raise exception 'FAIL link kept'; end if;
  if exists(select 1 from private.line_conversation_turns where actor_id=u2) then raise exception 'FAIL conversation kept'; end if;
  if not exists(select 1 from public.household_members where household_id=h and user_id=u2 and family_role='mama') then
    raise exception 'FAIL seat removed'; end if;

  -- A 7-day code; a newer code retires the older one.
  old_raw := public.server_tx_create_member_line_link_token(u1,gen_random_uuid(),u2)->>'raw_token';
  result := public.server_tx_create_member_line_link_token(u1,gen_random_uuid(),u2);
  raw := result->>'raw_token';
  if (result->>'expires_at')::timestamptz < now() + interval '6 days 23 hours' then raise exception 'FAIL code is not 7 days'; end if;
  rejected := false;
  begin perform public.server_tx_claim_line_link_token('Urealmama00000000000000000000000', old_raw);
  exception when others then rejected := true; end;
  if not rejected then raise exception 'FAIL retired code still works'; end if;

  -- The partner's own LINE (here the same LINE id the stand-in used) takes the seat.
  perform public.server_tx_claim_line_link_token('Ustandin0000000000000000000000000', raw);
  if not exists(select 1 from private.line_user_links where user_id=u2 and status='active'
    and line_user_id='Ustandin0000000000000000000000000') then raise exception 'FAIL seat not linked to the new LINE'; end if;
  if (public.server_tx_resolve_line_actor('Ustandin0000000000000000000000000')->>'user_id')::uuid<>u2 then
    raise exception 'FAIL LINE does not resolve to the seat'; end if;
end $$;
reset role;
rollback;
select 'member_line_handover: PASS' as result;

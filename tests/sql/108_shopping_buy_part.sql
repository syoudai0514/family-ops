-- 2026-10-07: buying only part of a bundled list item keeps the rest on the list.
\set ON_ERROR_STOP on
begin;

insert into auth.users(id) values
  ('10800000-0000-0000-0000-000000000001'),
  ('10800000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_hh uuid; v_item uuid; v_op uuid:=gen_random_uuid(); v_res jsonb; v_again jsonb;
  v_failed boolean;
begin
  v_hh:=(public.server_tx_create_household('10800000-0000-0000-0000-000000000001',gen_random_uuid(),'Buy Part HH','Owner')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role)
  values(v_hh,'10800000-0000-0000-0000-000000000002','adult');

  v_item:=(public.server_tx_add_shopping_item('10800000-0000-0000-0000-000000000001',gen_random_uuid(),
    '食器用洗剤とパパ用のシャンプーとリンスの購入','store','10800000-0000-0000-0000-000000000001',null,null)->>'shopping_item_id')::uuid;

  v_res:=public.server_tx_shopping_buy_part_v1('10800000-0000-0000-0000-000000000001',v_op,v_item,
    '食器用洗剤','パパ用のシャンプーとリンス','line');

  if (select title||'/'||status from public.shopping_items where id=v_item)<>'パパ用のシャンプーとリンス/assigned' then
    raise exception 'FAIL buy-part: the rest must stay open, renamed, with its assignee';
  end if;
  if (select assignee_id from public.shopping_items where id=v_item)<>'10800000-0000-0000-0000-000000000001' then
    raise exception 'FAIL buy-part: the open item must keep its assignee';
  end if;
  if not exists(select 1 from public.shopping_items where household_id=v_hh and title='食器用洗剤' and status='purchased') then
    raise exception 'FAIL buy-part: the bought part must be its own purchased item';
  end if;

  -- A replay returns the same answer and creates nothing more.
  v_again:=public.server_tx_shopping_buy_part_v1('10800000-0000-0000-0000-000000000001',v_op,v_item,
    '食器用洗剤','パパ用のシャンプーとリンス','line');
  if v_again<>v_res or (select count(*) from public.shopping_items where household_id=v_hh)<>2 then
    raise exception 'FAIL buy-part: replay must be idempotent';
  end if;

  -- A purchased item cannot be split again; identical titles are refused.
  v_failed:=false;
  begin
    perform public.server_tx_shopping_buy_part_v1('10800000-0000-0000-0000-000000000001',gen_random_uuid(),
      (v_res->>'bought_item_id')::uuid,'牛乳','卵','line');
  exception when others then
    if sqlerrm<>'INVALID_SHOPPING_TRANSITION' then raise; end if;
    v_failed:=true;
  end;
  if not v_failed then raise exception 'FAIL buy-part: a purchased item must not be split'; end if;

  v_failed:=false;
  begin
    perform public.server_tx_shopping_buy_part_v1('10800000-0000-0000-0000-000000000001',gen_random_uuid(),v_item,'同じ','同じ','line');
  exception when others then
    if sqlerrm<>'INVALID_INPUT' then raise; end if;
    v_failed:=true;
  end;
  if not v_failed then raise exception 'FAIL buy-part: identical titles must be refused'; end if;
end $$;

reset role;
set role authenticated;
do $$
begin
  perform public.server_tx_shopping_buy_part_v1(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),'a','b','line');
  raise exception 'FAIL buy-part: authenticated must not call the command';
exception when insufficient_privilege then null;
end $$;
reset role;

rollback;

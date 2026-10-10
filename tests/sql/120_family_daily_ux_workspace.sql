\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  u1 uuid:=gen_random_uuid(); u2 uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  hh uuid; other_hh uuid; op uuid:=gen_random_uuid(); payload jsonb; saved jsonb; again jsonb; readback jsonb;
  t uuid; req jsonb; preview jsonb; invite jsonb;
begin
  insert into auth.users(id) values(u1),(u2),(outsider);
  hh:=(public.server_tx_create_household(u1,gen_random_uuid(),'UX family','Owner')->>'household_id')::uuid;
  other_hh:=(public.server_tx_create_household(outsider,gen_random_uuid(),'Other family','Other')->>'household_id')::uuid;
  perform public.server_tx_family_setup(u1,gen_random_uuid(),'finish_later','{}'::jsonb);
  if not exists(select 1 from public.households where id=hh and dropoff_pickup_setup_completed_at is not null
    and evening_routine_setup_completed_at is not null and onboarding_preview_completed_at is not null) then
    raise exception 'FAIL: deferred onboarding remains blocked'; end if;
  if exists(select 1 from public.households where id=other_hh and onboarding_preview_completed_at is not null) then
    raise exception 'FAIL: deferred onboarding crossed household'; end if;
  payload:=jsonb_build_object('display_name','子どもA','school_display_name','園A','class_display_name','花組',
    'effective_from','2026-10-01','recognition_aliases',jsonb_build_array('花ぐみ'));
  saved:=public.server_tx_family_setup(u1,op,'save_context',payload);
  again:=public.server_tx_family_setup(u1,op,'save_context',payload);
  if saved is distinct from again or (select count(*) from public.family_children where household_id=hh)<>1 then
    raise exception 'FAIL: response-lost save duplicates child'; end if;
  begin
    perform public.server_tx_family_setup(u1,op,'save_context',payload||jsonb_build_object('display_name','別名'));
    raise exception 'FAIL: changed retry accepted';
  exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if; end;
  begin
    perform public.server_tx_family_setup(outsider,gen_random_uuid(),'save_context',payload||saved);
    raise exception 'FAIL: foreign child modified';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  readback:=public.server_read_family_setup(u1);
  if jsonb_array_length(readback->'children')<>1 or readback::text like '%line_user_id%' then
    raise exception 'FAIL: setup read loses children or leaks LINE identity'; end if;
  if jsonb_array_length(public.server_read_family_setup(outsider)->'children')<>0 then raise exception 'FAIL: read crossed household'; end if;
  -- Recovery invalidates old unused links, while receipts never store raw tokens.
  invite:=public.server_tx_create_household_invite(u1,gen_random_uuid());
  saved:=public.server_tx_family_setup(u1,gen_random_uuid(),'reissue_invite','{}');
  if saved->>'raw_token' is null or (select count(*) from private.household_invites where household_id=hh and expires_at>now() and used_at is null)<>1 then
    raise exception 'FAIL: invite recovery failed'; end if;
  if exists(select 1 from private.mutation_receipts where actor_id=u1 and result_payload ? 'raw_token') then
    raise exception 'FAIL: raw invite token persisted in receipt'; end if;
  insert into public.household_members(household_id,user_id,member_role) values(hh,u2,'adult');
  t:=(public.server_tx_create_task(u1,gen_random_uuid(),'交代する用事','chore','2026-10-12',null,u1,'whole','anytime',null)->>'task_id')::uuid;
  req:=public.server_tx_create_assignment_change_request(u1,gen_random_uuid(),t,u2,'お願いできますか','once');
  preview:=public.server_read_assignment_preview(u2,(req->>'request_id')::uuid,(req->>'attempt_id')::uuid);
  if (preview->>'stale')::boolean or jsonb_array_length(preview->'targets')<>1 or preview#>>'{targets,0,to_user_id}'<>u2::text then
    raise exception 'FAIL: exact assignment preview incorrect: %',preview; end if;
  update public.task_instances set revision=revision+1 where id=t;
  if not (public.server_read_assignment_preview(u2,(req->>'request_id')::uuid,(req->>'attempt_id')::uuid)->>'stale')::boolean then
    raise exception 'FAIL: stale assignment preview stays confirmable'; end if;
  begin
    perform public.server_read_assignment_preview(outsider,(req->>'request_id')::uuid,(req->>'attempt_id')::uuid);
    raise exception 'FAIL: foreign request preview readable';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  if has_function_privilege('authenticated','public.server_tx_family_setup(uuid,uuid,text,jsonb)','execute')
    or has_function_privilege('anon','public.server_read_family_setup(uuid)','execute') then raise exception 'FAIL: service adapter exposed'; end if;
  readback:=jsonb_build_object('morning_summary',jsonb_build_object('completed_count',1,'total_count',4),
    'schedule',jsonb_build_array(jsonb_build_object('title','面談')),
    'own_task_groups',jsonb_build_object('morning',jsonb_build_array(jsonb_build_object('title','朝の残り')),
      'evening',jsonb_build_array(jsonb_build_object('title','夜の作業')),
      'optional',jsonb_build_array(jsonb_build_object('title','任意の掃除'))));
  if private.fn_render_daily_brief_text_v4(readback,'evening') like '%朝 1/4 完了%'
    or private.fn_render_daily_brief_text_v4(readback,'evening') not like '%朝の残り%'
    or private.fn_render_daily_brief_text_v4(readback,'evening') not like '%余裕があれば%' then
    raise exception 'FAIL: brief compacting changed task truth'; end if;
end $$;
reset role;
rollback;
select 'family_daily_ux_workspace: PASS' as result;

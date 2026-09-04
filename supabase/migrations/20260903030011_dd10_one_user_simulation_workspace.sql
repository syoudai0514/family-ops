-- WP-DD10: one authenticated operator can run a clearly-labelled simulation.
-- The operator remains the execution principal; simulated roles are immutable
-- ActorRefs and never become auth users or household_members.

alter table public.test_simulation_contexts
  add column revision bigint not null default 1 check (revision >= 1);
create unique index test_simulation_one_active_per_operator_v1
  on public.test_simulation_contexts (household_id,operator_user_id) where status='active';

create or replace function private.fn_command_open_test_simulation_v1(
  p_household_id uuid,p_operator_user_id uuid,p_operator_actor_ref_id uuid,
  p_operation_id uuid,p_simulated_role text,p_label text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_claim jsonb; v_receipt_id uuid; v_context_id uuid; v_simulated_actor_ref_id uuid; v_result jsonb;
begin
  if p_simulated_role not in ('mama','papa') then raise exception 'SIMULATED_ROLE_INVALID'; end if;
  if length(coalesce(p_label,''))>160 then raise exception 'TEST_SIMULATION_LABEL_INVALID'; end if;
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_operator_actor_ref_id,null,p_operation_id,
    'test_simulation.open',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'simulated_role',p_simulated_role,'label',nullif(btrim(coalesce(p_label,'')), '')
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;
  if exists(select 1 from public.test_simulation_contexts
    where household_id=p_household_id and operator_user_id=p_operator_user_id and status='active') then
    raise exception 'TEST_SIMULATION_ALREADY_ACTIVE'; end if;
  insert into public.test_simulation_contexts(household_id,operator_user_id,label)
  values(p_household_id,p_operator_user_id,nullif(btrim(coalesce(p_label,'')),'')) returning id into v_context_id;
  insert into public.domain_actor_refs(household_id,actor_kind,test_context_id,simulated_role)
  values(p_household_id,'simulated_member',v_context_id,p_simulated_role) returning id into v_simulated_actor_ref_id;
  v_result:=jsonb_build_object('test_context_id',v_context_id,'simulated_actor_ref_id',v_simulated_actor_ref_id,
    'simulated_role',p_simulated_role,'display_label',private.fn_actor_display_label_v1(p_household_id,v_simulated_actor_ref_id),
    'status','active');
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'test_simulation_context',v_context_id,v_result);
  return v_result;
end;
$$;

create or replace function private.fn_command_archive_test_simulation_v1(
  p_household_id uuid,p_operator_user_id uuid,p_operator_actor_ref_id uuid,p_test_context_id uuid,
  p_expected_revision bigint,p_operation_id uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_claim jsonb; v_receipt_id uuid; v_context public.test_simulation_contexts%rowtype; v_result jsonb;
begin
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_operator_actor_ref_id,p_test_context_id,p_operation_id,
    'test_simulation.archive',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'test_context_id',p_test_context_id,'expected_revision',p_expected_revision
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;
  select * into v_context from public.test_simulation_contexts
  where household_id=p_household_id and id=p_test_context_id for update;
  if not found then raise exception 'TEST_CONTEXT_NOT_FOUND'; end if;
  if v_context.operator_user_id is distinct from p_operator_user_id then raise exception 'TEST_CONTEXT_OPERATOR_MISMATCH'; end if;
  if v_context.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_context.status<>'active' then raise exception 'TEST_CONTEXT_NOT_ACTIVE'; end if;
  update public.test_simulation_contexts set status='archived',archived_at=now(),revision=revision+1
  where id=p_test_context_id returning * into v_context;
  v_result:=jsonb_build_object('test_context_id',p_test_context_id,'status','archived','revision',v_context.revision,
    'production_conversion',false);
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'test_simulation_context',p_test_context_id,v_result);
  return v_result;
end;
$$;

create or replace function public.server_tx_open_test_simulation_v1(
  p_actor_id uuid,p_operation_id uuid,p_simulated_role text,p_label text default null
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c jsonb;
begin
  c:=private.fn_require_production_actor_context_v1(p_actor_id);
  return private.fn_command_open_test_simulation_v1(
    (c->>'household_id')::uuid,p_actor_id,(c->>'actor_ref_id')::uuid,p_operation_id,p_simulated_role,p_label
  );
end;
$$;

create or replace function public.server_tx_archive_test_simulation_v1(
  p_actor_id uuid,p_operation_id uuid,p_test_context_id uuid,p_expected_revision bigint
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c jsonb;
begin
  c:=private.fn_require_production_actor_context_v1(p_actor_id);
  return private.fn_command_archive_test_simulation_v1(
    (c->>'household_id')::uuid,p_actor_id,(c->>'actor_ref_id')::uuid,p_test_context_id,p_expected_revision,p_operation_id
  );
end;
$$;

create or replace function public.server_tx_get_test_simulation_workspace_v1(
  p_actor_id uuid,p_test_context_id uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare c jsonb; v_context public.test_simulation_contexts%rowtype; v_simulated public.domain_actor_refs%rowtype;
begin
  c:=private.fn_require_production_actor_context_v1(p_actor_id);
  select * into v_context from public.test_simulation_contexts
  where household_id=(c->>'household_id')::uuid and id=p_test_context_id;
  if not found then raise exception 'TEST_CONTEXT_NOT_FOUND'; end if;
  if v_context.operator_user_id is distinct from p_actor_id then raise exception 'TEST_CONTEXT_OPERATOR_MISMATCH'; end if;
  select * into v_simulated from public.domain_actor_refs
  where household_id=v_context.household_id and test_context_id=v_context.id and actor_kind='simulated_member';
  return jsonb_build_object(
    'test_context_id',v_context.id,'status',v_context.status,'revision',v_context.revision,
    'label',v_context.label,'simulated_actor_ref_id',v_simulated.id,'simulated_role',v_simulated.simulated_role,
    'display_label',private.fn_actor_display_label_v1(v_context.household_id,v_simulated.id),
    'deliveries',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'status',d.status,'payload',d.rendered_payload,'created_at',d.created_at) order by d.created_at desc)
      from private.test_delivery_outbox d where d.test_context_id=v_context.id),'[]'::jsonb)
  );
end;
$$;

revoke all on function private.fn_command_open_test_simulation_v1(uuid,uuid,uuid,uuid,text,text) from public,anon,authenticated;
revoke all on function private.fn_command_archive_test_simulation_v1(uuid,uuid,uuid,uuid,bigint,uuid) from public,anon,authenticated;
grant execute on function private.fn_command_open_test_simulation_v1(uuid,uuid,uuid,uuid,text,text) to service_role;
grant execute on function private.fn_command_archive_test_simulation_v1(uuid,uuid,uuid,uuid,bigint,uuid) to service_role;
revoke all on function public.server_tx_open_test_simulation_v1(uuid,uuid,text,text) from public,anon,authenticated;
revoke all on function public.server_tx_archive_test_simulation_v1(uuid,uuid,uuid,bigint) from public,anon,authenticated;
revoke all on function public.server_tx_get_test_simulation_workspace_v1(uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_open_test_simulation_v1(uuid,uuid,text,text) to service_role;
grant execute on function public.server_tx_archive_test_simulation_v1(uuid,uuid,uuid,bigint) to service_role;
grant execute on function public.server_tx_get_test_simulation_workspace_v1(uuid,uuid) to service_role;

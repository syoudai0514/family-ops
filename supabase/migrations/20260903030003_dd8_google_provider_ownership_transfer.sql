-- WP-DD8: Family Event/Google provider authority source.
--
-- This migration only establishes ownership transfer, revalidation, and audit
-- controls.  It deliberately does not enable a Family Event Google writer or
-- perform any provider mutation.  Writer activation remains P1-gated.

create or replace function private.fn_preserve_transferred_calendar_mirror_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  -- Task trigger/reconciliation may still call the legacy enqueue path.  Once
  -- a special mirror has been transferred, that path must be a no-op rather
  -- than silently reclaiming the same provider identity.
  if old.ownership_transfer_state = 'transferred' then
    if new.ownership_transfer_state = 'transferred' then
      return old;
    end if;
    raise exception 'TASK_MIRROR_TRANSFERRED';
  end if;
  return new;
end;
$$;
revoke all on function private.fn_preserve_transferred_calendar_mirror_v1()
  from public, anon, authenticated;
grant execute on function private.fn_preserve_transferred_calendar_mirror_v1()
  to service_role;
drop trigger if exists family_ops_calendar_mirrors_preserve_transferred_v1
  on private.family_ops_calendar_mirrors;
create trigger family_ops_calendar_mirrors_preserve_transferred_v1
  before update on private.family_ops_calendar_mirrors
  for each row execute function private.fn_preserve_transferred_calendar_mirror_v1();

create or replace function private.fn_guard_family_event_provider_writer_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not new.writer_enabled then return new; end if;
  if new.test_context_id is not null then raise exception 'TEST_SIDE_EFFECT_FORBIDDEN'; end if;
  if new.ownership_transfer_state <> 'active'
     or new.provider_identity_revalidated_at is null
     or nullif(btrim(coalesce(new.last_external_etag, '')), '') is null then
    raise exception 'FAMILY_EVENT_PROVIDER_IDENTITY_NOT_REVALIDATED';
  end if;

  if exists (
    select 1 from private.family_ops_calendar_mirrors m
    where m.calendar_connection_id = new.calendar_connection_id
      and m.provider_event_id = new.google_event_id
      and m.ownership_transfer_state <> 'transferred'
      and m.sync_state <> 'deleted'
  ) then raise exception 'FAMILY_EVENT_PROVIDER_OWNER_CONFLICT_TASK_MIRROR'; end if;

  if exists (
    select 1 from private.family_ops_calendar_target_deletions d
    where d.calendar_connection_id = new.calendar_connection_id
      and d.provider_event_id = new.google_event_id
      and d.ownership_transfer_state = 'delete_owned'
      and d.sync_state <> 'deleted'
  ) then raise exception 'FAMILY_EVENT_PROVIDER_OWNER_CONFLICT_TARGET_DELETE'; end if;

  if exists (
    select 1 from private.family_ops_calendar_orphaned_mirrors o
    where o.calendar_connection_id = new.calendar_connection_id
      and o.provider_event_id = new.google_event_id
      and (o.adoption_blocked
        or o.provider_identity_revalidated_at is null
        or o.provider_revalidated_etag is distinct from new.last_external_etag)
  ) then raise exception 'FAMILY_EVENT_PROVIDER_ORPHAN_REVALIDATION_REQUIRED'; end if;
  return new;
end;
$$;

-- A deletion row alone is never authorization to issue DELETE.  Claim and
-- pre-provider authorization both re-check that ownership was not transferred.
create or replace function public.server_tx_claim_family_ops_calendar_target_deletion(
  p_worker_id text,p_lease_seconds integer default 120
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_job private.family_ops_calendar_target_deletions%rowtype; v_lease uuid:=gen_random_uuid();
begin
  if coalesce(p_worker_id,'')='' then raise exception 'INVALID_INPUT'; end if;
  select * into v_job from private.family_ops_calendar_target_deletions d
  where d.ownership_transfer_state='delete_owned'
    and ((d.sync_state in ('pending','failed') and d.next_attempt_at<=now())
      or (d.sync_state='processing' and d.lease_until<now()))
    and not exists (
      select 1 from public.family_event_external_links l
      where l.calendar_connection_id=d.calendar_connection_id
        and l.google_event_id=d.provider_event_id
        and l.ownership_transfer_state in ('validated','active')
    )
  order by d.next_attempt_at,d.created_at for update skip locked limit 1;
  if not found then return null; end if;
  update private.family_ops_calendar_target_deletions
  set sync_state='processing',lease_token=v_lease,
      lease_until=now()+make_interval(secs=>greatest(coalesce(p_lease_seconds,120),30)),
      attempts=attempts+1,updated_at=now()
  where id=v_job.id returning * into v_job;
  return jsonb_build_object('id',v_job.id,'household_id',v_job.household_id,
    'calendar_connection_id',v_job.calendar_connection_id,'projection_key',v_job.projection_key,
    'provider_event_id',v_job.provider_event_id,'lease_token',v_lease);
end $$;

create or replace function public.server_tx_authorize_family_ops_calendar_target_deletion(
  p_id uuid,p_lease_token uuid
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_job private.family_ops_calendar_target_deletions%rowtype;
begin
  select * into v_job from private.family_ops_calendar_target_deletions
  where id=p_id for update;
  if not found or v_job.sync_state<>'processing' or v_job.lease_token is distinct from p_lease_token
     or v_job.lease_until<=now() then
    return jsonb_build_object('authorized',false,'reason','LEASE_OR_JOB_STALE');
  end if;
  if v_job.ownership_transfer_state<>'delete_owned' or exists (
    select 1 from public.family_event_external_links l
    where l.calendar_connection_id=v_job.calendar_connection_id
      and l.google_event_id=v_job.provider_event_id
      and l.ownership_transfer_state in ('validated','active')
  ) then
    update private.family_ops_calendar_target_deletions
    set ownership_transfer_state='superseded',sync_state='blocked',lease_token=null,lease_until=null,
        ownership_transfer_block_reason='FAMILY_EVENT_PROVIDER_OWNERSHIP',updated_at=now()
    where id=v_job.id;
    return jsonb_build_object('authorized',false,'reason','FAMILY_EVENT_PROVIDER_OWNERSHIP');
  end if;
  return jsonb_build_object('authorized',true);
end $$;

create or replace function public.server_tx_complete_family_ops_calendar_target_deletion(
  p_id uuid,p_lease_token uuid
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_authorized jsonb;
begin
  v_authorized:=public.server_tx_authorize_family_ops_calendar_target_deletion(p_id,p_lease_token);
  if coalesce((v_authorized->>'authorized')::boolean,false) is not true then
    return v_authorized || jsonb_build_object('ok',false,'superseded',true);
  end if;
  update private.family_ops_calendar_target_deletions
  set sync_state='deleted',lease_token=null,lease_until=null,last_error=null,updated_at=now()
  where id=p_id and sync_state='processing' and lease_token=p_lease_token
    and ownership_transfer_state='delete_owned';
  if not found then raise exception 'GOOGLE_SYNC_LEASE_LOST'; end if;
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.server_tx_fail_family_ops_calendar_target_deletion(
  p_id uuid,p_lease_token uuid,p_error text
) returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  update private.family_ops_calendar_target_deletions
  set sync_state='failed',lease_token=null,lease_until=null,
      last_error=left(coalesce(p_error,'unknown'),1000),
      next_attempt_at=now()+make_interval(secs=>(2^least(attempts,6))::integer*30),updated_at=now()
  where id=p_id and sync_state='processing' and lease_token=p_lease_token
    and ownership_transfer_state='delete_owned';
  if not found then raise exception 'GOOGLE_SYNC_LEASE_LOST'; end if;
  return jsonb_build_object('ok',true);
end $$;

create or replace function private.fn_transfer_task_mirror_to_family_event_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_operation_id uuid,
  p_family_event_id uuid,p_calendar_connection_id uuid,p_projection_key text,
  p_provider_event_id text,p_provider_etag text,p_external_snapshot jsonb,
  p_provider_revalidated_at timestamptz,p_link_mode text default 'family_ops_owned'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_claim jsonb; v_receipt_id uuid; v_mirror private.family_ops_calendar_mirrors%rowtype;
  v_event public.family_events%rowtype; v_deletion private.family_ops_calendar_target_deletions%rowtype;
  v_link public.family_event_external_links%rowtype; v_result jsonb;
begin
  if p_link_mode not in ('family_ops_owned','external_follow')
     or nullif(btrim(coalesce(p_provider_event_id,'')),'') is null
     or nullif(btrim(coalesce(p_provider_etag,'')),'') is null
     or p_provider_revalidated_at is null
     or p_external_snapshot is null or jsonb_typeof(p_external_snapshot)<>'object' then
    raise exception 'INVALID_INPUT';
  end if;
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,null,p_operation_id,
    'family_event.provider_transfer',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'family_event_id',p_family_event_id,'calendar_connection_id',p_calendar_connection_id,
      'projection_key',p_projection_key,'provider_event_id',p_provider_event_id,
      'provider_etag',p_provider_etag,'external_snapshot',p_external_snapshot,
      'provider_revalidated_at',p_provider_revalidated_at,'link_mode',p_link_mode
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;

  select * into v_event from public.family_events
  where household_id=p_household_id and id=p_family_event_id for update;
  if not found or v_event.test_context_id is not null then raise exception 'FAMILY_EVENT_NOT_TRANSFER_ELIGIBLE'; end if;
  select * into v_mirror from private.family_ops_calendar_mirrors
  where household_id=p_household_id and projection_key=p_projection_key for update;
  if not found or v_mirror.kind<>'special'
     or v_mirror.calendar_connection_id<>p_calendar_connection_id
     or v_mirror.provider_event_id is distinct from p_provider_event_id then
    raise exception 'TASK_MIRROR_PROVIDER_IDENTITY_MISMATCH';
  end if;
  if v_mirror.ownership_transfer_state='transferred' then raise exception 'TASK_MIRROR_ALREADY_TRANSFERRED'; end if;
  if v_mirror.sync_state='deleted' then raise exception 'TASK_MIRROR_PROVIDER_EVENT_DELETED'; end if;
  if v_mirror.sync_state='processing' and v_mirror.lease_until>now() then
    raise exception 'TASK_MIRROR_PROCESSING_LEASE_ACTIVE';
  end if;

  for v_deletion in
    select * from private.family_ops_calendar_target_deletions d
    where d.household_id=p_household_id and d.calendar_connection_id=p_calendar_connection_id
      and d.projection_key=p_projection_key and d.provider_event_id=p_provider_event_id
    for update
  loop
    if v_deletion.sync_state='deleted' then raise exception 'TARGET_DELETION_ALREADY_COMPLETED'; end if;
    if v_deletion.sync_state='processing' and v_deletion.lease_until>now() then
      raise exception 'TARGET_DELETION_PROCESSING_LEASE_ACTIVE';
    end if;
  end loop;

  if exists (
    select 1 from private.family_ops_calendar_orphaned_mirrors o
    where o.household_id=p_household_id and o.calendar_connection_id=p_calendar_connection_id
      and o.provider_event_id=p_provider_event_id
      and (o.adoption_blocked or o.provider_identity_revalidated_at is null
        or o.provider_revalidated_etag is distinct from p_provider_etag)
  ) then raise exception 'FAMILY_EVENT_PROVIDER_ORPHAN_REVALIDATION_REQUIRED'; end if;

  select * into v_link from public.family_event_external_links
  where calendar_connection_id=p_calendar_connection_id and google_event_id=p_provider_event_id for update;
  if found and v_link.family_event_id<>p_family_event_id then raise exception 'FAMILY_EVENT_PROVIDER_IDENTITY_ALREADY_LINKED'; end if;
  if not found then
    insert into public.family_event_external_links (
      household_id,family_event_id,calendar_connection_id,google_event_id,link_mode,
      last_external_owned_field_snapshot,last_external_etag,last_reconciled_at,
      provider_identity_revalidated_at,writer_enabled,ownership_transfer_state,test_context_id
    ) values (
      p_household_id,p_family_event_id,p_calendar_connection_id,p_provider_event_id,p_link_mode,
      p_external_snapshot,p_provider_etag,now(),p_provider_revalidated_at,false,'validated',null
    ) returning * into v_link;
  else
    update public.family_event_external_links
    set link_mode=p_link_mode,last_external_owned_field_snapshot=p_external_snapshot,
        last_external_etag=p_provider_etag,last_reconciled_at=now(),
        provider_identity_revalidated_at=p_provider_revalidated_at,
        writer_enabled=false,ownership_transfer_state='validated'
    where id=v_link.id returning * into v_link;
  end if;

  update private.family_ops_calendar_mirrors
  set ownership_transfer_state='transferred',ownership_transfer_block_reason='FAMILY_EVENT_PROVIDER_TRANSFER',
      sync_state='blocked',lease_token=null,lease_until=null,updated_at=now()
  where household_id=p_household_id and projection_key=p_projection_key;
  update private.family_ops_calendar_target_deletions
  set ownership_transfer_state='superseded',ownership_transfer_block_reason='FAMILY_EVENT_PROVIDER_TRANSFER',
      sync_state='blocked',lease_token=null,lease_until=null,updated_at=now()
  where household_id=p_household_id and calendar_connection_id=p_calendar_connection_id
    and projection_key=p_projection_key and provider_event_id=p_provider_event_id
    and ownership_transfer_state='delete_owned';

  v_result:=jsonb_build_object('family_event_id',p_family_event_id,'external_link_id',v_link.id,
    'provider_event_id',p_provider_event_id,'provider_etag',p_provider_etag,
    'writer_enabled',false,'ownership_transfer_state','validated');
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'family_event',p_family_event_id,v_result);
  return v_result;
end $$;

create or replace function private.fn_activate_family_event_provider_writer_v1(
  p_household_id uuid,p_family_event_id uuid,p_external_link_id uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_enabled boolean; v_link public.family_event_external_links%rowtype;
begin
  select writer_enabled and not mutation_paused and release_stage='P1' into v_enabled
  from private.canonical_capability_gates where capability='family_event_authority_v1';
  if coalesce(v_enabled,false) is not true then raise exception 'FAMILY_EVENT_PROVIDER_WRITER_NOT_ENABLED'; end if;
  select * into v_link from public.family_event_external_links
  where household_id=p_household_id and id=p_external_link_id and family_event_id=p_family_event_id for update;
  if not found then raise exception 'FAMILY_EVENT_EXTERNAL_LINK_NOT_FOUND'; end if;
  update public.family_event_external_links
  set ownership_transfer_state='active',writer_enabled=true
  where id=v_link.id;
  return jsonb_build_object('external_link_id',v_link.id,'writer_enabled',true);
end $$;

create or replace function private.canonical_google_provider_owner_audit_v1()
returns table(
  household_id uuid,calendar_connection_id uuid,provider_event_id text,
  active_owner_count bigint,active_owner_paths text[],orphan_blocked boolean
) language sql stable security definer set search_path='' as $$
  with paths as (
    select m.household_id,m.calendar_connection_id,m.provider_event_id,'task_mirror'::text path
    from private.family_ops_calendar_mirrors m
    where m.provider_event_id is not null and m.ownership_transfer_state<>'transferred'
      and m.sync_state<>'deleted'
    union all
    select d.household_id,d.calendar_connection_id,d.provider_event_id,'target_deletion'::text
    from private.family_ops_calendar_target_deletions d
    where d.ownership_transfer_state='delete_owned' and d.sync_state<>'deleted'
    union all
    select l.household_id,l.calendar_connection_id,l.google_event_id,'family_event_writer'::text
    from public.family_event_external_links l
    where l.writer_enabled and l.ownership_transfer_state='active' and l.test_context_id is null
  ), grouped as (
    select household_id,calendar_connection_id,provider_event_id,count(*)::bigint active_owner_count,
      array_agg(path order by path) active_owner_paths
    from paths group by household_id,calendar_connection_id,provider_event_id
  ), orphans as (
    select o.household_id,o.calendar_connection_id,o.provider_event_id,
      bool_or(o.adoption_blocked or o.provider_identity_revalidated_at is null) orphan_blocked
    from private.family_ops_calendar_orphaned_mirrors o
    group by o.household_id,o.calendar_connection_id,o.provider_event_id
  )
  select coalesce(g.household_id,o.household_id),coalesce(g.calendar_connection_id,o.calendar_connection_id),
    coalesce(g.provider_event_id,o.provider_event_id),coalesce(g.active_owner_count,0),
    coalesce(g.active_owner_paths,array[]::text[]),coalesce(o.orphan_blocked,false)
  from grouped g full join orphans o using (household_id,calendar_connection_id,provider_event_id);
$$;

revoke all on function public.server_tx_claim_family_ops_calendar_target_deletion(text,integer) from public,anon,authenticated;
revoke all on function public.server_tx_authorize_family_ops_calendar_target_deletion(uuid,uuid) from public,anon,authenticated;
revoke all on function public.server_tx_complete_family_ops_calendar_target_deletion(uuid,uuid) from public,anon,authenticated;
revoke all on function public.server_tx_fail_family_ops_calendar_target_deletion(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.server_tx_claim_family_ops_calendar_target_deletion(text,integer) to service_role;
grant execute on function public.server_tx_authorize_family_ops_calendar_target_deletion(uuid,uuid) to service_role;
grant execute on function public.server_tx_complete_family_ops_calendar_target_deletion(uuid,uuid) to service_role;
grant execute on function public.server_tx_fail_family_ops_calendar_target_deletion(uuid,uuid,text) to service_role;
revoke all on function private.fn_transfer_task_mirror_to_family_event_v1(uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,jsonb,timestamptz,text) from public,anon,authenticated;
revoke all on function private.fn_activate_family_event_provider_writer_v1(uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function private.canonical_google_provider_owner_audit_v1() from public,anon,authenticated;
grant execute on function private.fn_transfer_task_mirror_to_family_event_v1(uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,jsonb,timestamptz,text) to service_role;
grant execute on function private.fn_activate_family_event_provider_writer_v1(uuid,uuid,uuid) to service_role;
grant execute on function private.canonical_google_provider_owner_audit_v1() to service_role;

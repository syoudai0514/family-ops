-- Independent re-review remediation for PR #45.
-- Forward-only.  This migration does not activate Family Event Google writes,
-- OCR/AI/Storage adapters, P1, production readers, or production delivery.
--
-- HIGH-1 (DD8): represent provider mutation attempts durably so ownership
-- transfer cannot race an HTTP request that outlives the ordinary worker lease.
-- HIGH-2 (DD9): minimize pre-review durable values before persistence; free
-- text remains only in the private raw source and is never copied into the
-- structured fact/candidate stores before human confirmation.

-- ==========================================================================
-- DD8: durable provider-mutation in-flight / uncertainty fence
-- ==========================================================================

create table if not exists private.google_provider_mutation_fences (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null,
  calendar_connection_id uuid not null,
  provider_event_id text not null,
  owner_type text not null check (owner_type in ('task_mirror','target_deletion')),
  projection_key text,
  target_deletion_id uuid,
  owner_lease_token uuid not null,
  mutation_kind text not null check (mutation_kind in ('upsert','delete')),
  state text not null default 'inflight'
    check (state in ('inflight','completed','uncertain','reconciled')),
  started_at timestamptz not null default now(),
  request_deadline_at timestamptz not null,
  uncertainty_quarantine_until timestamptz not null,
  finished_at timestamptz,
  outcome text,
  provider_status integer,
  provider_result_etag text,
  revalidated_at timestamptz,
  revalidated_etag text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (owner_type='task_mirror' and projection_key is not null and target_deletion_id is null)
    or
    (owner_type='target_deletion' and target_deletion_id is not null)
  )
);

revoke all on table private.google_provider_mutation_fences from public,anon,authenticated;
grant select,insert,update,delete on table private.google_provider_mutation_fences to service_role;

create unique index if not exists google_provider_mutation_fences_one_unresolved_identity_v1
  on private.google_provider_mutation_fences(calendar_connection_id,provider_event_id)
  where state in ('inflight','uncertain');
create index if not exists google_provider_mutation_fences_owner_v1
  on private.google_provider_mutation_fences(owner_type,projection_key,target_deletion_id,owner_lease_token);
create index if not exists google_provider_mutation_fences_readiness_v1
  on private.google_provider_mutation_fences(state,uncertainty_quarantine_until);

create or replace function private.fn_mark_provider_mutation_fence_expired_v1(
  p_calendar_connection_id uuid,p_provider_event_id text
) returns integer
language plpgsql
security definer
set search_path=''
as $$
declare v_count integer;
begin
  update private.google_provider_mutation_fences f
  set state='uncertain',
      finished_at=coalesce(f.finished_at,f.request_deadline_at),
      outcome=coalesce(f.outcome,'REQUEST_DEADLINE_ELAPSED'),
      updated_at=now()
  where f.calendar_connection_id=p_calendar_connection_id
    and f.provider_event_id=p_provider_event_id
    and f.state='inflight'
    and f.request_deadline_at<=now();
  get diagnostics v_count=row_count;
  return v_count;
end;
$$;
revoke all on function private.fn_mark_provider_mutation_fence_expired_v1(uuid,text)
  from public,anon,authenticated;
grant execute on function private.fn_mark_provider_mutation_fence_expired_v1(uuid,text)
  to service_role;

-- Every authorization now atomically establishes a durable provider-call
-- fence.  A second authorization by the same lease means the previous awaited
-- HTTP attempt has returned (the only caller is the sequential Edge worker),
-- so that prior attempt can be closed before a 412 retry creates the next one.
create or replace function public.server_tx_authorize_family_ops_calendar_mirror(
  p_household_id uuid,
  p_projection_key text,
  p_lease_token uuid,
  p_calendar_connection_id uuid,
  p_provider_event_id text
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_mirror private.family_ops_calendar_mirrors%rowtype;
  v_expected_event_id text;
  v_fence_id uuid;
  v_deadline timestamptz;
  v_reason text;
begin
  if p_household_id is null
     or nullif(btrim(coalesce(p_projection_key,'')),'') is null
     or p_lease_token is null
     or p_calendar_connection_id is null
     or nullif(btrim(coalesce(p_provider_event_id,'')),'') is null then
    return jsonb_build_object('authorized',false,'reason','INVALID_PROVIDER_FENCE_INPUT');
  end if;

  select * into v_mirror
  from private.family_ops_calendar_mirrors m
  where m.household_id=p_household_id and m.projection_key=p_projection_key
  for update;

  if not found
     or v_mirror.sync_state<>'processing'
     or v_mirror.lease_token is distinct from p_lease_token
     or v_mirror.lease_until is null
     or v_mirror.lease_until<=now() then
    return jsonb_build_object('authorized',false,'reason','LEASE_OR_JOB_STALE');
  end if;
  if v_mirror.ownership_transfer_state='transferred' then
    return jsonb_build_object('authorized',false,'reason','TASK_MIRROR_TRANSFERRED');
  end if;
  if v_mirror.calendar_connection_id is distinct from p_calendar_connection_id then
    return jsonb_build_object('authorized',false,'reason','PROVIDER_CONNECTION_CHANGED');
  end if;

  v_expected_event_id:=coalesce(
    v_mirror.provider_event_id,
    'fo'||substr(md5(v_mirror.household_id::text||':'||v_mirror.projection_key),1,32)
  );
  if v_expected_event_id is distinct from p_provider_event_id then
    return jsonb_build_object('authorized',false,'reason','PROVIDER_IDENTITY_CHANGED');
  end if;

  if not exists (
    select 1 from public.calendar_connections c
    where c.id=v_mirror.calendar_connection_id
      and c.household_id=v_mirror.household_id
      and c.active and not c.reauth_required and c.is_family_write_target
  ) then
    return jsonb_build_object('authorized',false,'reason','CALENDAR_TARGET_CHANGED');
  end if;

  if exists (
    select 1 from public.family_event_external_links l
    where l.calendar_connection_id=v_mirror.calendar_connection_id
      and l.google_event_id=v_expected_event_id
      and l.ownership_transfer_state in ('validated','active')
  ) then
    return jsonb_build_object('authorized',false,'reason','FAMILY_EVENT_PROVIDER_OWNERSHIP');
  end if;

  if exists (
    select 1 from private.family_ops_calendar_target_deletions d
    where d.calendar_connection_id=v_mirror.calendar_connection_id
      and d.provider_event_id=v_expected_event_id
      and d.ownership_transfer_state='delete_owned'
      and d.sync_state<>'deleted'
  ) then
    return jsonb_build_object('authorized',false,'reason','TARGET_DELETION_PROVIDER_OWNERSHIP');
  end if;

  if exists (
    select 1 from private.family_ops_calendar_orphaned_mirrors o
    where o.household_id=v_mirror.household_id
      and o.calendar_connection_id=v_mirror.calendar_connection_id
      and o.provider_event_id=v_expected_event_id
      and (
        o.adoption_blocked
        or o.provider_identity_revalidated_at is null
        or o.provider_revalidated_etag is null
        or (v_mirror.provider_etag is not null
          and o.provider_revalidated_etag is distinct from v_mirror.provider_etag)
      )
  ) then
    return jsonb_build_object('authorized',false,'reason','ORPHAN_PROVIDER_REVALIDATION_REQUIRED');
  end if;

  perform private.fn_mark_provider_mutation_fence_expired_v1(
    v_mirror.calendar_connection_id,v_expected_event_id
  );

  -- Sequential retry proof: the Edge worker can reach a second authorization
  -- for the same lease only after the previous awaited provider call returned.
  update private.google_provider_mutation_fences f
  set state='completed',finished_at=now(),outcome='NEXT_AUTHORIZATION_AFTER_PROVIDER_RETURN',updated_at=now()
  where f.calendar_connection_id=v_mirror.calendar_connection_id
    and f.provider_event_id=v_expected_event_id
    and f.owner_type='task_mirror'
    and f.projection_key=v_mirror.projection_key
    and f.owner_lease_token=p_lease_token
    and f.state='inflight';

  select case when f.state='inflight' then 'PROVIDER_MUTATION_INFLIGHT'
                   else 'PROVIDER_MUTATION_DRAIN_REVALIDATION_REQUIRED' end
    into v_reason
  from private.google_provider_mutation_fences f
  where f.calendar_connection_id=v_mirror.calendar_connection_id
    and f.provider_event_id=v_expected_event_id
    and f.state in ('inflight','uncertain')
  order by f.started_at desc limit 1;
  if v_reason is not null then
    return jsonb_build_object('authorized',false,'reason',v_reason);
  end if;

  -- Worker lease and provider-call fence are intentionally separate.  The
  -- provider-call deadline is short; an unresolved call remains represented
  -- even after this ordinary worker lease later expires.
  update private.family_ops_calendar_mirrors
  set lease_until=greatest(lease_until,now()+interval '120 seconds'),updated_at=now()
  where household_id=p_household_id and projection_key=p_projection_key
    and sync_state='processing' and lease_token=p_lease_token
    and ownership_transfer_state<>'transferred'
  returning * into v_mirror;
  if not found then
    return jsonb_build_object('authorized',false,'reason','LEASE_OR_JOB_STALE');
  end if;

  v_deadline:=now()+interval '20 seconds';
  begin
    insert into private.google_provider_mutation_fences(
      household_id,calendar_connection_id,provider_event_id,owner_type,projection_key,
      owner_lease_token,mutation_kind,state,started_at,request_deadline_at,
      uncertainty_quarantine_until
    ) values (
      v_mirror.household_id,v_mirror.calendar_connection_id,v_expected_event_id,
      'task_mirror',v_mirror.projection_key,p_lease_token,
      case when v_mirror.desired_action='delete' then 'delete' else 'upsert' end,
      'inflight',now(),v_deadline,v_deadline+interval '120 seconds'
    ) returning id into v_fence_id;
  exception when unique_violation then
    return jsonb_build_object('authorized',false,'reason','PROVIDER_MUTATION_INFLIGHT');
  end;

  return jsonb_build_object(
    'authorized',true,
    'calendar_connection_id',v_mirror.calendar_connection_id,
    'provider_event_id',v_expected_event_id,
    'lease_until',v_mirror.lease_until,
    'mutation_fence_id',v_fence_id,
    'request_deadline_at',v_deadline
  );
end;
$$;

create or replace function public.server_tx_authorize_family_ops_calendar_target_deletion(
  p_id uuid,p_lease_token uuid
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_job private.family_ops_calendar_target_deletions%rowtype;
  v_fence_id uuid;
  v_deadline timestamptz;
  v_reason text;
begin
  select * into v_job from private.family_ops_calendar_target_deletions
  where id=p_id for update;
  if not found or v_job.sync_state<>'processing'
     or v_job.lease_token is distinct from p_lease_token
     or v_job.lease_until is null or v_job.lease_until<=now() then
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

  perform private.fn_mark_provider_mutation_fence_expired_v1(
    v_job.calendar_connection_id,v_job.provider_event_id
  );

  update private.google_provider_mutation_fences f
  set state='completed',finished_at=now(),outcome='NEXT_AUTHORIZATION_AFTER_PROVIDER_RETURN',updated_at=now()
  where f.calendar_connection_id=v_job.calendar_connection_id
    and f.provider_event_id=v_job.provider_event_id
    and f.owner_type='target_deletion'
    and f.target_deletion_id=v_job.id
    and f.owner_lease_token=p_lease_token
    and f.state='inflight';

  select case when f.state='inflight' then 'PROVIDER_MUTATION_INFLIGHT'
                   else 'PROVIDER_MUTATION_DRAIN_REVALIDATION_REQUIRED' end
    into v_reason
  from private.google_provider_mutation_fences f
  where f.calendar_connection_id=v_job.calendar_connection_id
    and f.provider_event_id=v_job.provider_event_id
    and f.state in ('inflight','uncertain')
  order by f.started_at desc limit 1;
  if v_reason is not null then
    return jsonb_build_object('authorized',false,'reason',v_reason);
  end if;

  update private.family_ops_calendar_target_deletions
  set lease_until=greatest(lease_until,now()+interval '120 seconds'),updated_at=now()
  where id=v_job.id and sync_state='processing' and lease_token=p_lease_token
    and ownership_transfer_state='delete_owned'
  returning * into v_job;
  if not found then return jsonb_build_object('authorized',false,'reason','LEASE_OR_JOB_STALE'); end if;

  v_deadline:=now()+interval '20 seconds';
  begin
    insert into private.google_provider_mutation_fences(
      household_id,calendar_connection_id,provider_event_id,owner_type,target_deletion_id,
      projection_key,owner_lease_token,mutation_kind,state,started_at,request_deadline_at,
      uncertainty_quarantine_until
    ) values (
      v_job.household_id,v_job.calendar_connection_id,v_job.provider_event_id,
      'target_deletion',v_job.id,v_job.projection_key,p_lease_token,'delete','inflight',
      now(),v_deadline,v_deadline+interval '120 seconds'
    ) returning id into v_fence_id;
  exception when unique_violation then
    return jsonb_build_object('authorized',false,'reason','PROVIDER_MUTATION_INFLIGHT');
  end;

  return jsonb_build_object(
    'authorized',true,'lease_until',v_job.lease_until,
    'mutation_fence_id',v_fence_id,'request_deadline_at',v_deadline
  );
end;
$$;

-- A successful owner completion proves the awaited provider call returned.
-- A failure/exception is conservative: provider outcome is uncertain and the
-- identity must drain + be re-GET/revalidated before transfer.
create or replace function public.server_tx_complete_family_ops_calendar_mirror(
  p_household_id uuid,p_projection_key text,p_lease_token uuid,
  p_provider_event_id text,p_provider_etag text,p_deleted boolean
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
begin
  update private.google_provider_mutation_fences f
  set state='completed',finished_at=now(),outcome='OWNER_COMPLETED',
      provider_result_etag=coalesce(p_provider_etag,f.provider_result_etag),updated_at=now()
  where f.household_id=p_household_id and f.owner_type='task_mirror'
    and f.projection_key=p_projection_key and f.owner_lease_token=p_lease_token
    and f.state='inflight';

  update private.family_ops_calendar_mirrors
  set provider_event_id=coalesce(p_provider_event_id,provider_event_id),
      provider_etag=coalesce(p_provider_etag,provider_etag),
      sync_state=case when p_deleted then 'deleted' else 'synced' end,
      desired_action=case when p_deleted then 'delete' else 'upsert' end,
      lease_token=null,lease_until=null,last_error=null,updated_at=now()
  where household_id=p_household_id and projection_key=p_projection_key
    and sync_state='processing' and lease_token=p_lease_token;
  if not found then raise exception 'GOOGLE_SYNC_LEASE_LOST'; end if;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.server_tx_fail_family_ops_calendar_mirror(
  p_household_id uuid,p_projection_key text,p_lease_token uuid,p_error text
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
begin
  update private.google_provider_mutation_fences f
  set state='uncertain',finished_at=now(),outcome='OWNER_FAILED_PROVIDER_OUTCOME_UNKNOWN',
      uncertainty_quarantine_until=greatest(f.uncertainty_quarantine_until,now()+interval '120 seconds'),
      updated_at=now()
  where f.household_id=p_household_id and f.owner_type='task_mirror'
    and f.projection_key=p_projection_key and f.owner_lease_token=p_lease_token
    and f.state='inflight';

  update private.family_ops_calendar_mirrors
  set sync_state='failed',lease_token=null,lease_until=null,
      last_error=left(coalesce(p_error,'unknown'),1000),
      next_attempt_at=now()+make_interval(secs=>(2^least(attempts,6))::integer*30),updated_at=now()
  where household_id=p_household_id and projection_key=p_projection_key
    and sync_state='processing' and lease_token=p_lease_token;
  if not found then raise exception 'GOOGLE_SYNC_LEASE_LOST'; end if;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.server_tx_complete_family_ops_calendar_target_deletion(
  p_id uuid,p_lease_token uuid
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare v_job private.family_ops_calendar_target_deletions%rowtype;
begin
  select * into v_job from private.family_ops_calendar_target_deletions
  where id=p_id for update;
  if not found or v_job.sync_state<>'processing'
     or v_job.lease_token is distinct from p_lease_token
     or v_job.ownership_transfer_state<>'delete_owned' then
    raise exception 'GOOGLE_SYNC_LEASE_LOST';
  end if;
  if exists (
    select 1 from public.family_event_external_links l
    where l.calendar_connection_id=v_job.calendar_connection_id
      and l.google_event_id=v_job.provider_event_id
      and l.ownership_transfer_state in ('validated','active')
  ) then
    raise exception 'FAMILY_EVENT_PROVIDER_OWNERSHIP';
  end if;

  update private.google_provider_mutation_fences f
  set state='completed',finished_at=now(),outcome='OWNER_COMPLETED',updated_at=now()
  where f.owner_type='target_deletion' and f.target_deletion_id=p_id
    and f.owner_lease_token=p_lease_token and f.state='inflight';

  update private.family_ops_calendar_target_deletions
  set sync_state='deleted',lease_token=null,lease_until=null,last_error=null,updated_at=now()
  where id=p_id and sync_state='processing' and lease_token=p_lease_token
    and ownership_transfer_state='delete_owned';
  if not found then raise exception 'GOOGLE_SYNC_LEASE_LOST'; end if;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.server_tx_fail_family_ops_calendar_target_deletion(
  p_id uuid,p_lease_token uuid,p_error text
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
begin
  update private.google_provider_mutation_fences f
  set state='uncertain',finished_at=now(),outcome='OWNER_FAILED_PROVIDER_OUTCOME_UNKNOWN',
      uncertainty_quarantine_until=greatest(f.uncertainty_quarantine_until,now()+interval '120 seconds'),
      updated_at=now()
  where f.owner_type='target_deletion' and f.target_deletion_id=p_id
    and f.owner_lease_token=p_lease_token and f.state='inflight';

  update private.family_ops_calendar_target_deletions
  set sync_state='failed',lease_token=null,lease_until=null,
      last_error=left(coalesce(p_error,'unknown'),1000),
      next_attempt_at=now()+make_interval(secs=>(2^least(attempts,6))::integer*30),updated_at=now()
  where id=p_id and sync_state='processing' and lease_token=p_lease_token
    and ownership_transfer_state='delete_owned';
  if not found then raise exception 'GOOGLE_SYNC_LEASE_LOST'; end if;
  return jsonb_build_object('ok',true);
end;
$$;

revoke all on function public.server_tx_authorize_family_ops_calendar_mirror(uuid,text,uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.server_tx_authorize_family_ops_calendar_target_deletion(uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.server_tx_complete_family_ops_calendar_mirror(uuid,text,uuid,text,text,boolean)
  from public,anon,authenticated;
revoke all on function public.server_tx_fail_family_ops_calendar_mirror(uuid,text,uuid,text)
  from public,anon,authenticated;
revoke all on function public.server_tx_complete_family_ops_calendar_target_deletion(uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.server_tx_fail_family_ops_calendar_target_deletion(uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function public.server_tx_authorize_family_ops_calendar_mirror(uuid,text,uuid,uuid,text) to service_role;
grant execute on function public.server_tx_authorize_family_ops_calendar_target_deletion(uuid,uuid) to service_role;
grant execute on function public.server_tx_complete_family_ops_calendar_mirror(uuid,text,uuid,text,text,boolean) to service_role;
grant execute on function public.server_tx_fail_family_ops_calendar_mirror(uuid,text,uuid,text) to service_role;
grant execute on function public.server_tx_complete_family_ops_calendar_target_deletion(uuid,uuid) to service_role;
grant execute on function public.server_tx_fail_family_ops_calendar_target_deletion(uuid,uuid,text) to service_role;

-- Transfer requires provider-call drain and a provider observation *after* the
-- quarantine window for every uncertain attempt.  It also requires the supplied
-- provider revalidation to be later than every known completed provider call.
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
  v_quarantine_until timestamptz; v_latest_completed_at timestamptz;
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

  for v_deletion in
    select * from private.family_ops_calendar_target_deletions d
    where d.household_id=p_household_id and d.calendar_connection_id=p_calendar_connection_id
      and d.projection_key=p_projection_key and d.provider_event_id=p_provider_event_id
    for update
  loop
    if v_deletion.sync_state='deleted' then raise exception 'TARGET_DELETION_ALREADY_COMPLETED'; end if;
  end loop;

  perform private.fn_mark_provider_mutation_fence_expired_v1(
    p_calendar_connection_id,p_provider_event_id
  );

  if exists (
    select 1 from private.google_provider_mutation_fences f
    where f.calendar_connection_id=p_calendar_connection_id
      and f.provider_event_id=p_provider_event_id and f.state='inflight'
  ) then raise exception 'PROVIDER_MUTATION_INFLIGHT'; end if;

  select max(f.uncertainty_quarantine_until) into v_quarantine_until
  from private.google_provider_mutation_fences f
  where f.calendar_connection_id=p_calendar_connection_id
    and f.provider_event_id=p_provider_event_id and f.state='uncertain';
  if v_quarantine_until is not null then
    if now()<v_quarantine_until or p_provider_revalidated_at<v_quarantine_until then
      raise exception 'PROVIDER_MUTATION_DRAIN_REVALIDATION_REQUIRED';
    end if;
    update private.google_provider_mutation_fences f
    set state='reconciled',revalidated_at=p_provider_revalidated_at,
        revalidated_etag=p_provider_etag,
        outcome=coalesce(f.outcome,'STALE_PROVIDER_ATTEMPT_REVALIDATED'),updated_at=now()
    where f.calendar_connection_id=p_calendar_connection_id
      and f.provider_event_id=p_provider_event_id and f.state='uncertain';
  end if;

  select max(f.finished_at) into v_latest_completed_at
  from private.google_provider_mutation_fences f
  where f.calendar_connection_id=p_calendar_connection_id
    and f.provider_event_id=p_provider_event_id and f.state='completed';
  if v_latest_completed_at is not null and p_provider_revalidated_at<v_latest_completed_at then
    raise exception 'PROVIDER_REVALIDATION_AFTER_LAST_MUTATION_REQUIRED';
  end if;

  -- Ordinary worker lease is still a useful fast-path guard, but it is no
  -- longer the provider-call safety boundary.
  if v_mirror.sync_state='processing' and v_mirror.lease_until>now() then
    raise exception 'TASK_MIRROR_PROCESSING_LEASE_ACTIVE';
  end if;
  for v_deletion in
    select * from private.family_ops_calendar_target_deletions d
    where d.household_id=p_household_id and d.calendar_connection_id=p_calendar_connection_id
      and d.projection_key=p_projection_key and d.provider_event_id=p_provider_event_id
    for update
  loop
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
end;
$$;
revoke all on function private.fn_transfer_task_mirror_to_family_event_v1(uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,jsonb,timestamptz,text)
  from public,anon,authenticated;
grant execute on function private.fn_transfer_task_mirror_to_family_event_v1(uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,jsonb,timestamptz,text)
  to service_role;

-- The final readiness gate must see unresolved provider-call state, not only
-- logical owner rows.
create or replace function private.canonical_cutover_readiness_audit_v1()
returns table(audit_name text,issue_count bigint,blocks_p1 boolean)
language sql stable security definer set search_path='' as $$
  select 'canonical_'||r.issue_type,r.issue_count,true
  from private.canonical_foundation_reconciliation_v1() r
  union all
  select 'capability_not_r0',count(*),true
  from private.canonical_capability_gates
  where release_stage<>'R0' or reader_enabled or writer_enabled or not mutation_paused or p1_crossed_at is not null
  union all
  select 'production_notification_test_leakage',count(*),true
  from public.user_notifications where test_context_id is not null
  union all
  select 'production_outbox_test_leakage',count(*),true
  from private.notification_outbox where test_context_id is not null
  union all
  select 'google_write_test_leakage',count(*),true
  from private.google_write_operations where test_context_id is not null
  union all
  select 'google_projection_test_leakage',count(*),true
  from private.family_ops_calendar_mirrors m
  join public.task_instances t on t.id=m.task_instance_id and t.household_id=m.household_id
  where t.test_context_id is not null
  union all
  select 'provider_mutation_owner_overlap',count(*),true
  from private.canonical_google_provider_owner_audit_v1() a where a.active_owner_count>1
  union all
  select 'provider_mutation_fence_unresolved',count(*),true
  from private.google_provider_mutation_fences f where f.state in ('inflight','uncertain')
  union all
  select 'family_event_p1_unrevalidated_orphan',count(*),true
  from private.canonical_google_provider_owner_audit_v1() a
  join private.canonical_capability_gates g on g.capability='family_event_authority_v1'
  where g.release_stage='P1' and a.orphan_blocked;
$$;
revoke all on function private.canonical_cutover_readiness_audit_v1() from public,anon,authenticated;
grant execute on function private.canonical_cutover_readiness_audit_v1() to service_role;

-- ==========================================================================
-- DD9: pre-review durable minimization (values, not just object keys)
-- ==========================================================================

create or replace function private.fn_minimize_nursery_provider_metadata_v3(p_value jsonb)
returns jsonb language plpgsql immutable security invoker set search_path='' as $$
declare
  v_provider text:=lower(coalesce(p_value->>'provider','unknown'));
  v_result jsonb:='{}'::jsonb;
  v_value text;
begin
  if v_provider not in ('codmon','openai','google','manual','test','unknown') then
    v_provider:='unknown';
  end if;
  v_result:=jsonb_build_object('provider',v_provider);
  v_value:=nullif(p_value->>'model','');
  if v_value is not null then v_result:=v_result||jsonb_build_object('model_fingerprint',pg_catalog.md5(v_value)); end if;
  v_value:=nullif(p_value->>'model_version','');
  if v_value is not null then v_result:=v_result||jsonb_build_object('model_version_fingerprint',pg_catalog.md5(v_value)); end if;
  v_value:=nullif(p_value->>'extractor_version','');
  if v_value is not null then v_result:=v_result||jsonb_build_object('extractor_version_fingerprint',pg_catalog.md5(v_value)); end if;
  v_value:=nullif(p_value->>'schema_version','');
  if v_value is not null and v_value~'^[0-9]{1,6}$' then
    v_result:=v_result||jsonb_build_object('schema_version',v_value);
  end if;
  return v_result;
end;
$$;

create or replace function private.fn_minimize_nursery_school_context_v3(p_value jsonb)
returns jsonb language plpgsql immutable security invoker set search_path='' as $$
declare v_result jsonb:='{}'::jsonb; v_date date;
begin
  if p_value is null then return null; end if;
  if p_value ? 'child_school_context_id' then
    v_result:=v_result||jsonb_build_object('child_school_context_id',p_value->>'child_school_context_id');
  end if;
  if p_value ? 'effective_from' then
    begin v_date:=(p_value->>'effective_from')::date;
      v_result:=v_result||jsonb_build_object('effective_from',v_date);
    exception when others then null; end;
  end if;
  if p_value ? 'effective_to' then
    begin v_date:=(p_value->>'effective_to')::date;
      v_result:=v_result||jsonb_build_object('effective_to',v_date);
    exception when others then null; end;
  end if;
  return v_result;
end;
$$;

create or replace function private.fn_minimize_nursery_fact_value_v3(
  p_fact_kind text,p_value jsonb
) returns jsonb
language plpgsql
immutable
security invoker
set search_path=''
as $$
declare
  v_result jsonb:='{}'::jsonb;
  v_text text; v_date date; v_time time; v_quantity integer;
begin
  case p_fact_kind
    when 'event' then
      v_text:=btrim(coalesce(p_value->>'event_type',''));
      v_result:=v_result||jsonb_build_object('event_type',case v_text
        when '食育' then 'food_education'
        when '保護者会' then 'parent_meeting'
        when 'プール' then 'pool'
        when '遠足' then 'outing'
        when '健診' then 'health_check'
        when '参観' then 'observation_day'
        else 'other_review_required' end);
      if p_value ? 'all_day' and jsonb_typeof(p_value->'all_day')='boolean' then
        v_result:=v_result||jsonb_build_object('all_day',(p_value->>'all_day')::boolean);
      end if;
      if p_value ? 'date' then begin v_date:=(p_value->>'date')::date;
        v_result:=v_result||jsonb_build_object('date',v_date); exception when others then null; end; end if;
      if p_value ? 'start_date' then begin v_date:=(p_value->>'start_date')::date;
        v_result:=v_result||jsonb_build_object('start_date',v_date); exception when others then null; end; end if;
      if p_value ? 'end_date' then begin v_date:=(p_value->>'end_date')::date;
        v_result:=v_result||jsonb_build_object('end_date',v_date); exception when others then null; end; end if;
    when 'required_item' then
      v_text:=lower(btrim(coalesce(p_value->>'item','')));
      v_result:=jsonb_build_object('item_code',case v_text
        when 'エプロン' then 'apron' when 'apron' then 'apron'
        when 'タオル' then 'towel' when 'towel' then 'towel'
        when '水筒' then 'water_bottle' when 'water bottle' then 'water_bottle'
        when '帽子' then 'hat' when 'hat' then 'hat'
        when '着替え' then 'change_of_clothes'
        when '上履き' then 'indoor_shoes'
        when '水着' then 'swimsuit'
        when '水泳帽' then 'swim_cap'
        when 'おむつ' then 'diaper'
        when 'おしりふき' then 'wipes'
        else 'other_review_required' end);
      if p_value ? 'quantity' and jsonb_typeof(p_value->'quantity')='number' then
        begin v_quantity:=(p_value->>'quantity')::integer;
          if v_quantity between 1 and 20 then v_result:=v_result||jsonb_build_object('quantity',v_quantity); end if;
        exception when others then null; end;
      end if;
      -- note is intentionally discarded pre-review.
    when 'deadline' then
      v_result:=jsonb_build_object('deadline_kind','other_review_required');
      if p_value ? 'date' then begin v_date:=(p_value->>'date')::date;
        v_result:=v_result||jsonb_build_object('date',v_date); exception when others then null; end; end if;
      if p_value ? 'time' then begin v_time:=(p_value->>'time')::time;
        v_result:=v_result||jsonb_build_object('time',v_time); exception when others then null; end; end if;
      -- label is intentionally discarded pre-review.
    when 'recurrence' then
      v_text:=lower(btrim(coalesce(p_value->>'frequency','')));
      v_result:=jsonb_build_object('frequency',case when v_text in ('daily','weekly','monthly') then v_text else 'other_review_required' end);
      v_text:=lower(btrim(coalesce(p_value->>'day_of_week','')));
      if v_text in ('mon','tue','wed','thu','fri','sat','sun') then
        v_result:=v_result||jsonb_build_object('day_of_week',v_text);
      end if;
      if p_value ? 'until' then begin v_date:=(p_value->>'until')::date;
        v_result:=v_result||jsonb_build_object('until',v_date); exception when others then null; end; end if;
      -- label is intentionally discarded pre-review.
    when 'url' then
      -- Full URLs can carry names, email addresses or opaque roster IDs in
      -- path/query.  Keep only the fact that a URL needs review.
      v_result:=jsonb_build_object('review_required',true,'value_kind','url');
    when 'note' then
      v_result:=jsonb_build_object('review_required',true,'value_kind','note');
    else raise exception 'NURSERY_FACT_KIND_INVALID';
  end case;
  return v_result;
end;
$$;

create or replace function private.fn_minimize_nursery_ai_patch_v3(
  p_target_type text,p_patch jsonb
) returns jsonb
language plpgsql
immutable
security invoker
set search_path=''
as $$
declare
  v_result jsonb:='{}'::jsonb; v_date date; v_ts timestamptz; v_rrule text;
begin
  if p_target_type='task' then
    if p_patch ? 'scheduled_date' then begin v_date:=(p_patch->>'scheduled_date')::date;
      v_result:=v_result||jsonb_build_object('scheduled_date',v_date); exception when others then null; end; end if;
    if p_patch ? 'due_at' then begin v_ts:=(p_patch->>'due_at')::timestamptz;
      v_result:=v_result||jsonb_build_object('due_at',v_ts); exception when others then null; end; end if;
    if p_patch ? 'calendar_ends_at' then begin v_ts:=(p_patch->>'calendar_ends_at')::timestamptz;
      v_result:=v_result||jsonb_build_object('calendar_ends_at',v_ts); exception when others then null; end; end if;
  elsif p_target_type='family_event' then
    if p_patch ? 'all_day' and jsonb_typeof(p_patch->'all_day')='boolean' then
      v_result:=v_result||jsonb_build_object('all_day',(p_patch->>'all_day')::boolean);
    end if;
    if p_patch ? 'start_date' then begin v_date:=(p_patch->>'start_date')::date;
      v_result:=v_result||jsonb_build_object('start_date',v_date); exception when others then null; end; end if;
    if p_patch ? 'end_date' then begin v_date:=(p_patch->>'end_date')::date;
      v_result:=v_result||jsonb_build_object('end_date',v_date); exception when others then null; end; end if;
    if p_patch ? 'starts_at' then begin v_ts:=(p_patch->>'starts_at')::timestamptz;
      v_result:=v_result||jsonb_build_object('starts_at',v_ts); exception when others then null; end; end if;
    if p_patch ? 'ends_at' then begin v_ts:=(p_patch->>'ends_at')::timestamptz;
      v_result:=v_result||jsonb_build_object('ends_at',v_ts); exception when others then null; end; end if;
  elsif p_target_type='recurrence' then
    v_rrule:=upper(btrim(coalesce(p_patch->>'rrule','')));
    if v_rrule~'^FREQ=(DAILY|WEEKLY|MONTHLY)(;INTERVAL=[1-9][0-9]?)?(;BYDAY=(MO|TU|WE|TH|FR|SA|SU)(,(MO|TU|WE|TH|FR|SA|SU))*)?(;UNTIL=[0-9]{8})?$' then
      v_result:=v_result||jsonb_build_object('rrule',v_rrule);
    end if;
    if p_patch ? 'effective_from' then begin v_date:=(p_patch->>'effective_from')::date;
      v_result:=v_result||jsonb_build_object('effective_from',v_date); exception when others then null; end; end if;
    if p_patch ? 'effective_to' then begin v_date:=(p_patch->>'effective_to')::date;
      v_result:=v_result||jsonb_build_object('effective_to',v_date); exception when others then null; end; end if;
  elsif p_target_type='info' then
    if p_patch ? 'effective_from' then begin v_date:=(p_patch->>'effective_from')::date;
      v_result:=v_result||jsonb_build_object('effective_from',v_date); exception when others then null; end; end if;
    if p_patch ? 'effective_to' then begin v_date:=(p_patch->>'effective_to')::date;
      v_result:=v_result||jsonb_build_object('effective_to',v_date); exception when others then null; end; end if;
  else raise exception 'NURSERY_AI_CANDIDATE_INVALID';
  end if;
  if v_result='{}'::jsonb then v_result:=jsonb_build_object('review_required',true); end if;
  return v_result;
end;
$$;

-- The input validators remain strict structural guards.  The command below
-- additionally sanitizes every value before INSERT/UPDATE, which is the
-- durable privacy boundary the previous review found missing.
create or replace function private.fn_command_create_nursery_intake_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_test_context_id uuid,
  p_operation_id uuid,p_document_kind text,p_storage_object_key text,p_captured_at timestamptz,
  p_extraction_version text,p_provider_metadata jsonb,p_source text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_claim jsonb; v_receipt_id uuid; v_document_id uuid; v_extraction_id uuid; v_result jsonb;
  v_metadata jsonb;
begin
  if p_source not in ('line','pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  if p_document_kind not in ('codmon_notice','nursery_notice','monthly_schedule','school_notice','other_notice')
     or nullif(btrim(coalesce(p_extraction_version,'')),'') is null
     or p_extraction_version!~'^[A-Za-z0-9._-]{1,160}$' then
    raise exception 'NURSERY_DOCUMENT_INPUT_INVALID';
  end if;
  if nullif(btrim(coalesce(p_storage_object_key,'')),'') is null
     or length(p_storage_object_key)>512
     or p_storage_object_key~*'^[a-z][a-z0-9+.-]*://' then
    raise exception 'NURSERY_PRIVATE_OBJECT_KEY_REQUIRED';
  end if;
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,p_test_context_id,p_operation_id,
    'nursery.intake.create',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'document_kind',p_document_kind,'storage_object_key',p_storage_object_key,
      'captured_at',p_captured_at,'extraction_version',p_extraction_version,
      'provider_metadata',coalesce(p_provider_metadata,'{}'::jsonb),'source',p_source
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;
  perform private.fn_validate_nursery_provider_metadata_v2(coalesce(p_provider_metadata,'{}'::jsonb));
  v_metadata:=private.fn_minimize_nursery_provider_metadata_v3(coalesce(p_provider_metadata,'{}'::jsonb));

  insert into private.source_documents(
    household_id,uploaded_by_actor_ref_id,document_kind,storage_object_key,captured_at,test_context_id
  ) values (
    p_household_id,p_actor_ref_id,p_document_kind,p_storage_object_key,p_captured_at,p_test_context_id
  ) returning id into v_document_id;
  insert into private.document_extractions(
    household_id,source_document_id,extraction_version,provider_metadata,state,test_context_id
  ) values (
    p_household_id,v_document_id,p_extraction_version,v_metadata,'processing',p_test_context_id
  ) returning id into v_extraction_id;
  v_result:=jsonb_build_object('source_document_id',v_document_id,'extraction_id',v_extraction_id,
    'state','processing','side_effects','none');
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'source_document',v_document_id,v_result);
  return v_result;
end;
$$;

create or replace function private.fn_command_record_nursery_extraction_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_test_context_id uuid,
  p_operation_id uuid,p_extraction_id uuid,p_expected_revision bigint,
  p_school_context_candidate jsonb,p_source_facts jsonb,p_ai_candidates jsonb,p_source text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_claim jsonb; v_receipt_id uuid; v_extraction private.document_extractions%rowtype;
  v_fact jsonb; v_candidate jsonb; v_context_id uuid; v_fact_id uuid; v_candidate_id uuid;
  v_fact_count integer:=0; v_candidate_count integer:=0; v_revision bigint; v_result jsonb;
  v_top_level_key_count integer; v_minimized_fact jsonb; v_minimized_patch jsonb;
  v_minimized_school_context jsonb; v_locator text; v_target_id uuid; v_snapshot_hash text;
begin
  if p_source not in ('line','pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  if jsonb_typeof(coalesce(p_source_facts,'[]'::jsonb))<>'array'
     or jsonb_typeof(coalesce(p_ai_candidates,'[]'::jsonb))<>'array'
     or jsonb_array_length(coalesce(p_source_facts,'[]'::jsonb))>64
     or jsonb_array_length(coalesce(p_ai_candidates,'[]'::jsonb))>32
     or octet_length(coalesce(p_source_facts,'[]'::jsonb)::text)>32768
     or octet_length(coalesce(p_ai_candidates,'[]'::jsonb)::text)>32768 then
    raise exception 'NURSERY_EXTRACTION_PAYLOAD_INVALID';
  end if;
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,p_test_context_id,p_operation_id,
    'nursery.extraction.record',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'extraction_id',p_extraction_id,'expected_revision',p_expected_revision,
      'school_context_candidate',p_school_context_candidate,'source_facts',p_source_facts,
      'ai_candidates',p_ai_candidates,'source',p_source
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;
  perform private.fn_validate_nursery_school_context_candidate_v2(p_school_context_candidate);
  v_minimized_school_context:=private.fn_minimize_nursery_school_context_v3(p_school_context_candidate);

  if v_minimized_school_context ? 'child_school_context_id' then
    begin v_context_id:=(v_minimized_school_context->>'child_school_context_id')::uuid;
    exception when others then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end;
    if not exists(select 1 from public.child_school_contexts s
      where s.household_id=p_household_id and s.id=v_context_id and s.active) then
      raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED';
    end if;
  end if;

  select * into v_extraction from private.document_extractions
  where household_id=p_household_id and id=p_extraction_id for update;
  if not found then raise exception 'NURSERY_EXTRACTION_NOT_FOUND'; end if;
  if v_extraction.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_extraction.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_extraction.state not in ('processing','review') then raise exception 'NURSERY_EXTRACTION_NOT_RECORDABLE'; end if;

  for v_fact in select value from jsonb_array_elements(coalesce(p_source_facts,'[]'::jsonb)) loop
    if jsonb_typeof(v_fact)<>'object' then raise exception 'NURSERY_FACT_VALUE_INVALID'; end if;
    select count(*)::integer into v_top_level_key_count from jsonb_object_keys(v_fact);
    if v_top_level_key_count>6 or exists(
      select 1 from jsonb_object_keys(v_fact) as allowed_key(key)
      where key not in ('child_school_context_id','fact_kind','normalized_value','confidence_band','source_locator','source_label')
    ) then raise exception 'NURSERY_FACT_VALUE_INVALID'; end if;
    if coalesce(v_fact->>'fact_kind','') not in ('event','required_item','deadline','recurrence','url','note') then
      raise exception 'NURSERY_FACT_KIND_INVALID';
    end if;
    if coalesce(v_fact->>'confidence_band','') not in ('high','medium','low') then
      raise exception 'NURSERY_FACT_CONFIDENCE_INVALID';
    end if;
    begin v_context_id:=nullif(v_fact->>'child_school_context_id','')::uuid;
    exception when others then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end;
    if v_context_id is null or not exists (
      select 1 from public.child_school_contexts s
      where s.household_id=p_household_id and s.id=v_context_id and s.active
    ) then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end if;

    -- Validate the submitted shape, then persist only the minimized result.
    perform private.fn_validate_nursery_fact_value_v2(v_fact->>'fact_kind',v_fact->'normalized_value');
    v_minimized_fact:=private.fn_minimize_nursery_fact_value_v3(v_fact->>'fact_kind',v_fact->'normalized_value');
    v_locator:=nullif(v_fact->>'source_locator','');
    if v_locator is not null and v_locator!~'^(page|block|line|item):[0-9]{1,5}$' then v_locator:=null; end if;

    insert into private.document_facts(
      household_id,extraction_id,child_school_context_id,fact_kind,normalized_value,
      confidence_band,source_locator,fact_origin,test_context_id
    ) values (
      p_household_id,p_extraction_id,v_context_id,v_fact->>'fact_kind',v_minimized_fact,
      v_fact->>'confidence_band',v_locator,'source_explicit',p_test_context_id
    ) returning id into v_fact_id;
    v_fact_count:=v_fact_count+1;
  end loop;

  for v_candidate in select value from jsonb_array_elements(coalesce(p_ai_candidates,'[]'::jsonb)) loop
    if jsonb_typeof(v_candidate)<>'object' then raise exception 'NURSERY_AI_CANDIDATE_INVALID'; end if;
    select count(*)::integer into v_top_level_key_count from jsonb_object_keys(v_candidate);
    if v_top_level_key_count>7 or exists(
      select 1 from jsonb_object_keys(v_candidate) as allowed_key(key)
      where key not in ('child_school_context_id','target_type','target_id','proposed_patch','explanation','current_snapshot_hash','confidence_band')
    ) or coalesce(v_candidate->>'target_type','') not in ('family_event','task','recurrence','info')
      or jsonb_typeof(v_candidate->'proposed_patch')<>'object'
      or nullif(btrim(coalesce(v_candidate->>'explanation','')),'') is null
      or length(v_candidate->>'explanation')>500
      or coalesce(v_candidate->>'confidence_band','high') not in ('high','medium','low') then
      raise exception 'NURSERY_AI_CANDIDATE_INVALID';
    end if;
    begin v_context_id:=nullif(v_candidate->>'child_school_context_id','')::uuid;
    exception when others then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end;
    if v_context_id is null or not exists (
      select 1 from public.child_school_contexts s
      where s.household_id=p_household_id and s.id=v_context_id and s.active
    ) then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end if;

    perform private.fn_validate_nursery_ai_patch_v2(v_candidate->>'target_type',v_candidate->'proposed_patch');
    v_minimized_patch:=private.fn_minimize_nursery_ai_patch_v3(v_candidate->>'target_type',v_candidate->'proposed_patch');

    v_target_id:=null;
    if nullif(v_candidate->>'target_id','') is not null then
      begin v_target_id:=(v_candidate->>'target_id')::uuid;
      exception when others then raise exception 'NURSERY_AI_CANDIDATE_INVALID'; end;
    end if;
    v_snapshot_hash:=nullif(v_candidate->>'current_snapshot_hash','');
    if v_snapshot_hash is not null and v_snapshot_hash!~'^[0-9a-fA-F]{64}$' then
      raise exception 'NURSERY_AI_CANDIDATE_INVALID';
    end if;

    insert into public.change_candidates(
      household_id,target_type,target_id,source_type,source_ref,proposed_patch,current_snapshot_hash,test_context_id
    ) values (
      p_household_id,v_candidate->>'target_type',v_target_id,
      'ai_inference',p_extraction_id::text,
      v_minimized_patch||jsonb_build_object(
        'origin_label','ai_inference','reason_code','model_candidate_requires_review',
        'child_school_context_id',v_context_id
      ),v_snapshot_hash,p_test_context_id
    ) returning id into v_candidate_id;
    v_candidate_count:=v_candidate_count+1;
  end loop;

  update private.document_extractions
  set school_context_candidate=v_minimized_school_context,state='review',revision=revision+1
  where id=p_extraction_id returning revision into v_revision;
  v_result:=jsonb_build_object('extraction_id',p_extraction_id,'state','review','revision',v_revision,
    'source_fact_count',v_fact_count,'ai_candidate_count',v_candidate_count,'side_effects','none');
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'document_extraction',p_extraction_id,v_result);
  return v_result;
end;
$$;

revoke all on function private.fn_minimize_nursery_provider_metadata_v3(jsonb) from public,anon,authenticated,service_role;
revoke all on function private.fn_minimize_nursery_school_context_v3(jsonb) from public,anon,authenticated,service_role;
revoke all on function private.fn_minimize_nursery_fact_value_v3(text,jsonb) from public,anon,authenticated,service_role;
revoke all on function private.fn_minimize_nursery_ai_patch_v3(text,jsonb) from public,anon,authenticated,service_role;
revoke all on function private.fn_command_create_nursery_intake_v1(uuid,uuid,uuid,uuid,uuid,text,text,timestamptz,text,jsonb,text)
  from public,anon,authenticated;
revoke all on function private.fn_command_record_nursery_extraction_v1(uuid,uuid,uuid,uuid,uuid,uuid,bigint,jsonb,jsonb,jsonb,text)
  from public,anon,authenticated;
grant execute on function private.fn_command_create_nursery_intake_v1(uuid,uuid,uuid,uuid,uuid,text,text,timestamptz,text,jsonb,text)
  to service_role;
grant execute on function private.fn_command_record_nursery_extraction_v1(uuid,uuid,uuid,uuid,uuid,uuid,bigint,jsonb,jsonb,jsonb,text)
  to service_role;

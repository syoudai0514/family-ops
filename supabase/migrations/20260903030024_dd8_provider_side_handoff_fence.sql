-- DD8 independent re-review hardening: provider-side ownership handoff fence.
--
-- A finite client timeout/quarantine is NOT the correctness boundary. When a
-- provider mutation outcome is uncertain, ownership transfer now requires a
-- successful conditional PATCH of the Google event that writes a unique
-- handoff token and returns a NEW provider ETag. Old PATCH/DELETE attempts use
-- an older If-Match ETag and can no longer succeed after this fence. A stale
-- deterministic INSERT cannot overwrite the now-existing event id.
--
-- Family Event production writer activation remains disabled/R0.

create table if not exists private.google_provider_handoff_fences (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null,
  calendar_connection_id uuid not null,
  provider_event_id text not null,
  projection_key text not null,
  handoff_token uuid not null unique default gen_random_uuid(),
  state text not null default 'prepared'
    check (state in ('prepared','provider_fenced','consumed','cancelled')),
  prepared_at timestamptz not null default now(),
  if_match_etag text,
  provider_fenced_etag text,
  provider_fenced_at timestamptz,
  provider_snapshot jsonb,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(calendar_connection_id,provider_event_id,handoff_token)
);

revoke all on table private.google_provider_handoff_fences
  from public,anon,authenticated,service_role;

create unique index if not exists google_provider_handoff_fences_one_open_identity_v1
  on private.google_provider_handoff_fences(calendar_connection_id,provider_event_id)
  where state in ('prepared','provider_fenced');
create index if not exists google_provider_handoff_fences_projection_v1
  on private.google_provider_handoff_fences(household_id,projection_key,state);

create or replace function public.server_tx_prepare_google_provider_handoff_fence(
  p_household_id uuid,
  p_calendar_connection_id uuid,
  p_projection_key text,
  p_provider_event_id text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_mirror private.family_ops_calendar_mirrors%rowtype;
  v_existing private.google_provider_handoff_fences%rowtype;
  v_row private.google_provider_handoff_fences%rowtype;
begin
  if p_household_id is null or p_calendar_connection_id is null
     or nullif(btrim(coalesce(p_projection_key,'')),'') is null
     or nullif(btrim(coalesce(p_provider_event_id,'')),'') is null then
    raise exception 'INVALID_INPUT';
  end if;

  select * into v_mirror
  from private.family_ops_calendar_mirrors m
  where m.household_id=p_household_id
    and m.projection_key=p_projection_key
  for update;
  if not found
     or v_mirror.calendar_connection_id is distinct from p_calendar_connection_id
     or v_mirror.provider_event_id is distinct from p_provider_event_id then
    raise exception 'TASK_MIRROR_PROVIDER_IDENTITY_MISMATCH';
  end if;
  if v_mirror.ownership_transfer_state='transferred' then
    raise exception 'TASK_MIRROR_ALREADY_TRANSFERRED';
  end if;
  if v_mirror.sync_state='deleted' then
    raise exception 'TASK_MIRROR_PROVIDER_EVENT_DELETED';
  end if;

  perform private.fn_mark_provider_mutation_fence_expired_v1(
    p_calendar_connection_id,p_provider_event_id
  );

  if exists (
    select 1 from private.google_provider_mutation_fences f
    where f.calendar_connection_id=p_calendar_connection_id
      and f.provider_event_id=p_provider_event_id
      and f.state='inflight'
  ) then
    raise exception 'PROVIDER_MUTATION_INFLIGHT';
  end if;

  if not exists (
    select 1 from private.google_provider_mutation_fences f
    where f.calendar_connection_id=p_calendar_connection_id
      and f.provider_event_id=p_provider_event_id
      and f.state='uncertain'
  ) then
    return jsonb_build_object('required',false,'reason','NO_UNCERTAIN_PROVIDER_MUTATION');
  end if;

  select * into v_existing
  from private.google_provider_handoff_fences h
  where h.calendar_connection_id=p_calendar_connection_id
    and h.provider_event_id=p_provider_event_id
    and h.state in ('prepared','provider_fenced')
  for update;
  if found then
    return jsonb_build_object(
      'required',true,
      'handoff_token',v_existing.handoff_token,
      'state',v_existing.state,
      'provider_event_id',v_existing.provider_event_id
    );
  end if;

  insert into private.google_provider_handoff_fences(
    household_id,calendar_connection_id,provider_event_id,projection_key,state
  ) values (
    p_household_id,p_calendar_connection_id,p_provider_event_id,p_projection_key,'prepared'
  ) returning * into v_row;

  return jsonb_build_object(
    'required',true,
    'handoff_token',v_row.handoff_token,
    'state',v_row.state,
    'provider_event_id',v_row.provider_event_id
  );
end;
$$;

-- Confirmation is accepted only for a provider response that proves:
-- 1. the conditional PATCH used a concrete If-Match ETag;
-- 2. the returned ETag changed;
-- 3. the returned provider snapshot contains this exact unique handoff token;
-- 4. the returned event id is the exact provider identity being transferred.
create or replace function public.server_tx_confirm_google_provider_handoff_fence(
  p_handoff_token uuid,
  p_if_match_etag text,
  p_provider_etag text,
  p_provider_snapshot jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_row private.google_provider_handoff_fences%rowtype;
  v_snapshot_token text;
begin
  if p_handoff_token is null
     or nullif(btrim(coalesce(p_if_match_etag,'')),'') is null
     or nullif(btrim(coalesce(p_provider_etag,'')),'') is null
     or p_if_match_etag=p_provider_etag
     or p_provider_snapshot is null
     or jsonb_typeof(p_provider_snapshot)<>'object' then
    raise exception 'PROVIDER_HANDOFF_FENCE_CONFIRMATION_INVALID';
  end if;

  select * into v_row
  from private.google_provider_handoff_fences h
  where h.handoff_token=p_handoff_token
  for update;
  if not found then raise exception 'PROVIDER_HANDOFF_FENCE_NOT_FOUND'; end if;

  v_snapshot_token:=p_provider_snapshot#>>'{extendedProperties,private,familyOpsOwnershipFenceToken}';
  if v_snapshot_token is distinct from p_handoff_token::text
     or p_provider_snapshot->>'id' is distinct from v_row.provider_event_id then
    raise exception 'PROVIDER_HANDOFF_FENCE_CONFIRMATION_INVALID';
  end if;

  if v_row.state='provider_fenced' then
    if v_row.if_match_etag is distinct from p_if_match_etag
       or v_row.provider_fenced_etag is distinct from p_provider_etag
       or v_row.provider_snapshot is distinct from p_provider_snapshot then
      raise exception 'PROVIDER_HANDOFF_FENCE_CONFIRMATION_CONFLICT';
    end if;
    return jsonb_build_object(
      'confirmed',true,'handoff_token',v_row.handoff_token,
      'provider_etag',v_row.provider_fenced_etag,'state',v_row.state
    );
  end if;
  if v_row.state<>'prepared' then
    raise exception 'PROVIDER_HANDOFF_FENCE_NOT_PREPARED';
  end if;

  update private.google_provider_handoff_fences
  set state='provider_fenced',
      if_match_etag=p_if_match_etag,
      provider_fenced_etag=p_provider_etag,
      provider_fenced_at=now(),
      provider_snapshot=p_provider_snapshot,
      updated_at=now()
  where id=v_row.id
  returning * into v_row;

  return jsonb_build_object(
    'confirmed',true,'handoff_token',v_row.handoff_token,
    'provider_etag',v_row.provider_fenced_etag,'state',v_row.state
  );
end;
$$;

revoke all on function public.server_tx_prepare_google_provider_handoff_fence(uuid,uuid,text,text)
  from public,anon,authenticated;
revoke all on function public.server_tx_confirm_google_provider_handoff_fence(uuid,text,text,jsonb)
  from public,anon,authenticated;
grant execute on function public.server_tx_prepare_google_provider_handoff_fence(uuid,uuid,text,text)
  to service_role;
grant execute on function public.server_tx_confirm_google_provider_handoff_fence(uuid,text,text,jsonb)
  to service_role;

create or replace function private.fn_transfer_task_mirror_to_family_event_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_operation_id uuid,
  p_family_event_id uuid,p_calendar_connection_id uuid,p_projection_key text,
  p_provider_event_id text,p_provider_etag text,p_external_snapshot jsonb,
  p_provider_revalidated_at timestamptz,p_link_mode text default 'family_ops_owned'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_mirror private.family_ops_calendar_mirrors%rowtype;
  v_event public.family_events%rowtype;
  v_deletion private.family_ops_calendar_target_deletions%rowtype;
  v_link public.family_event_external_links%rowtype;
  v_handoff private.google_provider_handoff_fences%rowtype;
  v_result jsonb;
  v_latest_completed_at timestamptz;
  v_uncertain_count bigint;
  v_snapshot_token text;
begin
  if p_link_mode not in ('family_ops_owned','external_follow')
     or nullif(btrim(coalesce(p_provider_event_id,'')),'') is null
     or nullif(btrim(coalesce(p_provider_etag,'')),'') is null
     or p_provider_revalidated_at is null
     or p_external_snapshot is null
     or jsonb_typeof(p_external_snapshot)<>'object' then
    raise exception 'INVALID_INPUT';
  end if;

  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,null,p_operation_id,
    'family_event.provider_transfer',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'family_event_id',p_family_event_id,
      'calendar_connection_id',p_calendar_connection_id,
      'projection_key',p_projection_key,
      'provider_event_id',p_provider_event_id,
      'provider_etag',p_provider_etag,
      'external_snapshot',p_external_snapshot,
      'provider_revalidated_at',p_provider_revalidated_at,
      'link_mode',p_link_mode
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;

  select * into v_event
  from public.family_events
  where household_id=p_household_id and id=p_family_event_id
  for update;
  if not found or v_event.test_context_id is not null then
    raise exception 'FAMILY_EVENT_NOT_TRANSFER_ELIGIBLE';
  end if;

  select * into v_mirror
  from private.family_ops_calendar_mirrors
  where household_id=p_household_id and projection_key=p_projection_key
  for update;
  if not found or v_mirror.kind<>'special'
     or v_mirror.calendar_connection_id<>p_calendar_connection_id
     or v_mirror.provider_event_id is distinct from p_provider_event_id then
    raise exception 'TASK_MIRROR_PROVIDER_IDENTITY_MISMATCH';
  end if;
  if v_mirror.ownership_transfer_state='transferred' then
    raise exception 'TASK_MIRROR_ALREADY_TRANSFERRED';
  end if;
  if v_mirror.sync_state='deleted' then
    raise exception 'TASK_MIRROR_PROVIDER_EVENT_DELETED';
  end if;

  for v_deletion in
    select * from private.family_ops_calendar_target_deletions d
    where d.household_id=p_household_id
      and d.calendar_connection_id=p_calendar_connection_id
      and d.projection_key=p_projection_key
      and d.provider_event_id=p_provider_event_id
    for update
  loop
    if v_deletion.sync_state='deleted' then
      raise exception 'TARGET_DELETION_ALREADY_COMPLETED';
    end if;
  end loop;

  perform private.fn_mark_provider_mutation_fence_expired_v1(
    p_calendar_connection_id,p_provider_event_id
  );

  if exists (
    select 1 from private.google_provider_mutation_fences f
    where f.calendar_connection_id=p_calendar_connection_id
      and f.provider_event_id=p_provider_event_id
      and f.state='inflight'
  ) then
    raise exception 'PROVIDER_MUTATION_INFLIGHT';
  end if;

  select count(*) into v_uncertain_count
  from private.google_provider_mutation_fences f
  where f.calendar_connection_id=p_calendar_connection_id
    and f.provider_event_id=p_provider_event_id
    and f.state='uncertain';

  if v_uncertain_count>0 then
    -- A provider observation after an arbitrary wait is not enough: the stale
    -- request could complete after that GET. Require the provider-side ETag
    -- bump/handoff token instead.
    select * into v_handoff
    from private.google_provider_handoff_fences h
    where h.calendar_connection_id=p_calendar_connection_id
      and h.provider_event_id=p_provider_event_id
      and h.projection_key=p_projection_key
      and h.state='provider_fenced'
    for update;
    if not found then
      raise exception 'PROVIDER_HANDOFF_FENCE_REQUIRED';
    end if;

    v_snapshot_token:=p_external_snapshot#>>'{extendedProperties,private,familyOpsOwnershipFenceToken}';
    if v_handoff.provider_fenced_etag is distinct from p_provider_etag
       or v_handoff.provider_snapshot is distinct from p_external_snapshot
       or v_snapshot_token is distinct from v_handoff.handoff_token::text
       or v_handoff.if_match_etag is null
       or v_handoff.if_match_etag=v_handoff.provider_fenced_etag
       or v_handoff.provider_fenced_at is null then
      raise exception 'PROVIDER_HANDOFF_FENCE_EVIDENCE_MISMATCH';
    end if;

    update private.google_provider_mutation_fences f
    set state='reconciled',
        revalidated_at=v_handoff.provider_fenced_at,
        revalidated_etag=v_handoff.provider_fenced_etag,
        outcome=coalesce(f.outcome,'STALE_PROVIDER_ATTEMPT_PROVIDER_FENCED'),
        updated_at=now()
    where f.calendar_connection_id=p_calendar_connection_id
      and f.provider_event_id=p_provider_event_id
      and f.state='uncertain';
  else
    -- Normal no-uncertainty transfer still requires a provider observation
    -- after every completed provider mutation.
    select max(f.finished_at) into v_latest_completed_at
    from private.google_provider_mutation_fences f
    where f.calendar_connection_id=p_calendar_connection_id
      and f.provider_event_id=p_provider_event_id
      and f.state='completed';
    if v_latest_completed_at is not null
       and p_provider_revalidated_at<v_latest_completed_at then
      raise exception 'PROVIDER_REVALIDATION_AFTER_LAST_MUTATION_REQUIRED';
    end if;
  end if;

  -- Ordinary worker leases remain a fast-path guard; they are not the
  -- provider-call correctness boundary.
  if v_mirror.sync_state='processing' and v_mirror.lease_until>now() then
    raise exception 'TASK_MIRROR_PROCESSING_LEASE_ACTIVE';
  end if;
  for v_deletion in
    select * from private.family_ops_calendar_target_deletions d
    where d.household_id=p_household_id
      and d.calendar_connection_id=p_calendar_connection_id
      and d.projection_key=p_projection_key
      and d.provider_event_id=p_provider_event_id
    for update
  loop
    if v_deletion.sync_state='processing' and v_deletion.lease_until>now() then
      raise exception 'TARGET_DELETION_PROCESSING_LEASE_ACTIVE';
    end if;
  end loop;

  if exists (
    select 1 from private.family_ops_calendar_orphaned_mirrors o
    where o.household_id=p_household_id
      and o.calendar_connection_id=p_calendar_connection_id
      and o.provider_event_id=p_provider_event_id
      and (
        o.adoption_blocked
        or o.provider_identity_revalidated_at is null
        or o.provider_revalidated_etag is distinct from p_provider_etag
      )
  ) then
    raise exception 'FAMILY_EVENT_PROVIDER_ORPHAN_REVALIDATION_REQUIRED';
  end if;

  select * into v_link
  from public.family_event_external_links
  where calendar_connection_id=p_calendar_connection_id
    and google_event_id=p_provider_event_id
  for update;
  if found and v_link.family_event_id<>p_family_event_id then
    raise exception 'FAMILY_EVENT_PROVIDER_IDENTITY_ALREADY_LINKED';
  end if;

  if not found then
    insert into public.family_event_external_links(
      household_id,family_event_id,calendar_connection_id,google_event_id,link_mode,
      last_external_owned_field_snapshot,last_external_etag,last_reconciled_at,
      provider_identity_revalidated_at,writer_enabled,ownership_transfer_state,test_context_id
    ) values (
      p_household_id,p_family_event_id,p_calendar_connection_id,p_provider_event_id,p_link_mode,
      p_external_snapshot,p_provider_etag,now(),p_provider_revalidated_at,false,'validated',null
    ) returning * into v_link;
  else
    update public.family_event_external_links
    set link_mode=p_link_mode,
        last_external_owned_field_snapshot=p_external_snapshot,
        last_external_etag=p_provider_etag,
        last_reconciled_at=now(),
        provider_identity_revalidated_at=p_provider_revalidated_at,
        writer_enabled=false,
        ownership_transfer_state='validated'
    where id=v_link.id
    returning * into v_link;
  end if;

  update private.family_ops_calendar_mirrors
  set ownership_transfer_state='transferred',
      ownership_transfer_block_reason='FAMILY_EVENT_PROVIDER_TRANSFER',
      provider_etag=p_provider_etag,
      sync_state='blocked',
      lease_token=null,
      lease_until=null,
      updated_at=now()
  where household_id=p_household_id and projection_key=p_projection_key;

  update private.family_ops_calendar_target_deletions
  set ownership_transfer_state='superseded',
      ownership_transfer_block_reason='FAMILY_EVENT_PROVIDER_TRANSFER',
      sync_state='blocked',
      lease_token=null,
      lease_until=null,
      updated_at=now()
  where household_id=p_household_id
    and calendar_connection_id=p_calendar_connection_id
    and projection_key=p_projection_key
    and provider_event_id=p_provider_event_id
    and ownership_transfer_state='delete_owned';

  if v_uncertain_count>0 then
    update private.google_provider_handoff_fences
    set state='consumed',consumed_at=now(),updated_at=now()
    where id=v_handoff.id and state='provider_fenced';
    if not found then raise exception 'PROVIDER_HANDOFF_FENCE_CONSUME_FAILED'; end if;
  end if;

  v_result:=jsonb_build_object(
    'family_event_id',p_family_event_id,
    'external_link_id',v_link.id,
    'provider_event_id',p_provider_event_id,
    'provider_etag',p_provider_etag,
    'writer_enabled',false,
    'ownership_transfer_state','validated',
    'provider_handoff_fenced',v_uncertain_count>0
  );
  perform private.fn_complete_canonical_operation_v1(
    v_receipt_id,'family_event',p_family_event_id,v_result
  );
  return v_result;
end;
$$;

revoke all on function private.fn_transfer_task_mirror_to_family_event_v1(
  uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,jsonb,timestamptz,text
) from public,anon,authenticated;
grant execute on function private.fn_transfer_task_mirror_to_family_event_v1(
  uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,jsonb,timestamptz,text
) to service_role;

-- Prepared/provider-fenced handoff rows are release blockers until consumed or
-- explicitly cancelled. This prevents a partially completed provider barrier
-- from being invisible to DD11 readiness.
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
    and nullif(btrim(coalesce(m.provider_event_id,'')),'') is not null
  union all
  select 'provider_mutation_owner_overlap',count(*),true
  from private.canonical_google_provider_owner_audit_v1() a
  where a.active_owner_count>1
  union all
  select 'provider_mutation_fence_unresolved',count(*),true
  from private.google_provider_mutation_fences f
  where f.state in ('inflight','uncertain')
  union all
  select 'provider_handoff_fence_unconsumed',count(*),true
  from private.google_provider_handoff_fences h
  where h.state in ('prepared','provider_fenced')
  union all
  select 'family_event_p1_unrevalidated_orphan',count(*),true
  from private.canonical_google_provider_owner_audit_v1() a
  join private.canonical_capability_gates g on g.capability='family_event_authority_v1'
  where g.release_stage='P1' and a.orphan_blocked;
$$;
revoke all on function private.canonical_cutover_readiness_audit_v1()
  from public,anon,authenticated;
grant execute on function private.canonical_cutover_readiness_audit_v1()
  to service_role;

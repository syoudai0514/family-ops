-- PR #45 independent-source-review remediation regressions.
-- Covers DD8 stale-worker provider fencing, DD9 structured privacy boundaries,
-- and DD10 archive receipt replay after context archival.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid := '10000000-0000-0000-0000-000000000050';
  v_household uuid;
  v_owner_ref uuid;
  v_google_connection uuid;
  v_calendar_connection uuid;
  v_claim_calendar_connection uuid;
  v_provider_event_id text;
  v_provider_etag text;
  v_task_upsert uuid;
  v_task_delete uuid;
  v_event_upsert uuid;
  v_event_delete uuid;
  v_claim jsonb;
  v_auth jsonb;
  v_lease uuid;
  v_transfer jsonb;
  v_sim jsonb;
  v_archive_first jsonb;
  v_archive_retry jsonb;
  v_test_context uuid;
  v_error text;
begin
  insert into auth.users(id) values(v_owner) on conflict do nothing;
  insert into public.profiles(user_id,display_name)
  values(v_owner,'Source review remediation owner') on conflict do nothing;
  v_household := (public.server_tx_create_household(
    v_owner,'20000000-0000-0000-0000-000000000050','Remediation household','Asia/Tokyo'
  )->>'household_id')::uuid;
  select id into v_owner_ref from public.domain_actor_refs
  where household_id=v_household and actor_kind='real_user' and real_user_id=v_owner;

  insert into private.google_connections(
    household_id,owner_user_id,google_subject,encrypted_refresh_token,encryption_version,scopes,status
  ) values (
    v_household,v_owner,'remediation-google-subject','cipher',1,
    array['https://www.googleapis.com/auth/calendar.events'],'active'
  ) returning id into v_google_connection;
  -- OAuth v2 deliberately removed implicit write-target selection. The race
  -- fixture models a household that already made the explicit calendar choice.
  insert into public.calendar_connections(
    household_id,provider,external_calendar_id,google_connection_id,
    active,reauth_required,is_family_write_target
  ) values (
    v_household,'google','remediation@example.test',v_google_connection,
    true,false,true
  ) returning id into v_calendar_connection;

  -- -----------------------------------------------------------------------
  -- DD8 case A: seed only the durable queue row, then drive provider identity
  -- through the real claim -> complete lifecycle.  The fixture never invents
  -- provider_event_id/provider_etag directly.  After completion a real Task
  -- mutation re-enqueues the existing provider mirror for the race.
  -- -----------------------------------------------------------------------
  insert into public.task_instances(
    household_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,completion_mode,status,source,created_by,calendar_visibility
  ) values (
    v_household,'manual','DD8 UPSERT seed','school','anytime','2030-03-01',
    v_owner,'whole','todo','test',v_owner,'special'
  ) returning id into v_task_upsert;

  insert into private.family_ops_calendar_mirrors(
    household_id,projection_key,kind,local_date,task_instance_id,
    calendar_connection_id,desired_action,sync_state,next_attempt_at,
    ownership_transfer_state
  ) values (
    v_household,'special:'||v_task_upsert::text,'special','2030-03-01',v_task_upsert,
    v_calendar_connection,'upsert','pending','1800-01-01','task_owned'
  )
  on conflict (household_id,projection_key) do update
  set kind=excluded.kind,
      local_date=excluded.local_date,
      task_instance_id=excluded.task_instance_id,
      calendar_connection_id=excluded.calendar_connection_id,
      desired_action='upsert',sync_state='pending',attempts=0,
      next_attempt_at='1800-01-01',lease_token=null,lease_until=null,last_error=null,
      ownership_transfer_state='task_owned',updated_at=now();

  v_claim:=public.server_tx_claim_family_ops_calendar_mirror('dd8-race-upsert-seed',30);
  if v_claim is null
     or v_claim->>'projection_key'<>'special:'||v_task_upsert::text
     or v_claim->>'action'<>'upsert'
     or nullif(v_claim->>'lease_token','') is null then
    raise exception 'FAIL remediation DD8 A: seed UPSERT mirror was not claimed: %',v_claim;
  end if;
  v_lease:=(v_claim->>'lease_token')::uuid;
  perform public.server_tx_complete_family_ops_calendar_mirror(
    v_household,'special:'||v_task_upsert::text,v_lease,
    'dd8-race-upsert','etag-upsert',false
  );

  -- due_at/calendar_ends_at are production projection trigger columns and the
  -- pair is a valid timed Google event shape.
  update public.task_instances
  set due_at='2030-03-01 12:00+09'::timestamptz,
      calendar_ends_at='2030-03-01 13:00+09'::timestamptz
  where id=v_task_upsert;
  update private.family_ops_calendar_mirrors
  set next_attempt_at='1800-01-01'
  where household_id=v_household and projection_key='special:'||v_task_upsert::text;
  insert into public.family_events(
    household_id,title,all_day,starts_at,ends_at,calendar_sync_preference,created_by_actor_ref_id
  ) values (
    v_household,'DD8 UPSERT family event',false,'2030-03-01 09:00+09','2030-03-01 10:00+09',
    'family_ops_owned',v_owner_ref
  ) returning id into v_event_upsert;

  v_claim:=public.server_tx_claim_family_ops_calendar_mirror('dd8-race-upsert-worker',30);
  if v_claim is null
     or v_claim->>'projection_key'<>'special:'||v_task_upsert::text
     or v_claim->>'action'<>'upsert'
     or nullif(v_claim->>'lease_token','') is null then
    raise exception 'FAIL remediation DD8 A: expected UPSERT mirror was not claimed: %',v_claim;
  end if;
  v_lease:=(v_claim->>'lease_token')::uuid;
  select calendar_connection_id,provider_event_id,provider_etag
    into v_claim_calendar_connection,v_provider_event_id,v_provider_etag
  from private.family_ops_calendar_mirrors
  where household_id=v_household and projection_key='special:'||v_task_upsert::text;
  if v_claim_calendar_connection is null or nullif(v_provider_event_id,'') is null
     or nullif(v_provider_etag,'') is null then
    raise exception 'FAIL remediation DD8 A: completed provider identity was not retained';
  end if;

  begin
    perform private.fn_transfer_task_mirror_to_family_event_v1(
      v_household,v_owner,v_owner_ref,'20000000-0000-0000-0000-000000000150',
      v_event_upsert,v_claim_calendar_connection,'special:'||v_task_upsert::text,
      v_provider_event_id,v_provider_etag,jsonb_build_object('title','DD8 UPSERT family event'),
      now(),'family_ops_owned'
    );
    raise exception 'FAIL remediation DD8 A: active processing lease allowed transfer';
  exception when others then
    if sqlerrm not like '%TASK_MIRROR_PROCESSING_LEASE_ACTIVE%' then raise; end if;
  end;

  update private.family_ops_calendar_mirrors
  set lease_until=now()-interval '1 second'
  where household_id=v_household and projection_key='special:'||v_task_upsert::text;
  v_transfer:=private.fn_transfer_task_mirror_to_family_event_v1(
    v_household,v_owner,v_owner_ref,'20000000-0000-0000-0000-000000000151',
    v_event_upsert,v_claim_calendar_connection,'special:'||v_task_upsert::text,
    v_provider_event_id,v_provider_etag,jsonb_build_object('title','DD8 UPSERT family event'),
    now(),'family_ops_owned'
  );
  if v_transfer->>'ownership_transfer_state'<>'validated' then
    raise exception 'FAIL remediation DD8 A: transfer after expiry did not succeed';
  end if;
  v_auth:=public.server_tx_authorize_family_ops_calendar_mirror(
    v_household,'special:'||v_task_upsert::text,v_lease,v_claim_calendar_connection,v_provider_event_id
  );
  if coalesce((v_auth->>'authorized')::boolean,false) then
    raise exception 'FAIL remediation DD8 A: stale UPSERT worker retained provider authorization';
  end if;

  -- Exercise the same production enqueue trigger after transfer.  A legacy
  -- Task mutation must not reclaim a provider identity now owned by FamilyEvent.
  update public.task_instances
  set due_at='2030-03-01 14:00+09'::timestamptz,
      calendar_ends_at='2030-03-01 15:00+09'::timestamptz
  where id=v_task_upsert;
  if not exists(
    select 1 from private.family_ops_calendar_mirrors
    where household_id=v_household and projection_key='special:'||v_task_upsert::text
      and ownership_transfer_state='transferred' and sync_state='blocked'
  ) then raise exception 'FAIL remediation DD8 A: transferred mirror was re-enqueued'; end if;

  -- -----------------------------------------------------------------------
  -- DD8 case B: same provider-identity lifecycle, then a real Task cancel
  -- re-enqueues DELETE. Claim DELETE, expire its lease, transfer ownership,
  -- and prove stale DELETE auth plus target-deletion overlap are eliminated.
  -- -----------------------------------------------------------------------
  insert into public.task_instances(
    household_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,completion_mode,status,source,created_by,calendar_visibility
  ) values (
    v_household,'manual','DD8 DELETE seed','school','anytime','2030-03-02',
    v_owner,'whole','todo','test',v_owner,'special'
  ) returning id into v_task_delete;

  insert into private.family_ops_calendar_mirrors(
    household_id,projection_key,kind,local_date,task_instance_id,
    calendar_connection_id,desired_action,sync_state,next_attempt_at,
    ownership_transfer_state
  ) values (
    v_household,'special:'||v_task_delete::text,'special','2030-03-02',v_task_delete,
    v_calendar_connection,'upsert','pending','1800-01-01','task_owned'
  )
  on conflict (household_id,projection_key) do update
  set kind=excluded.kind,
      local_date=excluded.local_date,
      task_instance_id=excluded.task_instance_id,
      calendar_connection_id=excluded.calendar_connection_id,
      desired_action='upsert',sync_state='pending',attempts=0,
      next_attempt_at='1800-01-01',lease_token=null,lease_until=null,last_error=null,
      ownership_transfer_state='task_owned',updated_at=now();

  v_claim:=public.server_tx_claim_family_ops_calendar_mirror('dd8-race-delete-seed',30);
  if v_claim is null
     or v_claim->>'projection_key'<>'special:'||v_task_delete::text
     or v_claim->>'action'<>'upsert'
     or nullif(v_claim->>'lease_token','') is null then
    raise exception 'FAIL remediation DD8 B: seed UPSERT mirror was not claimed: %',v_claim;
  end if;
  v_lease:=(v_claim->>'lease_token')::uuid;
  perform public.server_tx_complete_family_ops_calendar_mirror(
    v_household,'special:'||v_task_delete::text,v_lease,
    'dd8-race-delete','etag-delete',false
  );

  insert into public.family_events(
    household_id,title,all_day,starts_at,ends_at,calendar_sync_preference,created_by_actor_ref_id
  ) values (
    v_household,'DD8 DELETE family event',false,'2030-03-02 09:00+09','2030-03-02 10:00+09',
    'family_ops_owned',v_owner_ref
  ) returning id into v_event_delete;
  update public.task_instances set status='cancelled' where id=v_task_delete;
  update private.family_ops_calendar_mirrors
  set next_attempt_at='1800-01-01'
  where household_id=v_household and projection_key='special:'||v_task_delete::text;

  v_claim:=public.server_tx_claim_family_ops_calendar_mirror('dd8-race-delete-worker',30);
  if v_claim is null
     or v_claim->>'projection_key'<>'special:'||v_task_delete::text
     or v_claim->>'action'<>'delete'
     or nullif(v_claim->>'lease_token','') is null then
    raise exception 'FAIL remediation DD8 B: expected DELETE mirror was not claimed: %',v_claim;
  end if;
  v_lease:=(v_claim->>'lease_token')::uuid;
  select calendar_connection_id,provider_event_id,provider_etag
    into v_claim_calendar_connection,v_provider_event_id,v_provider_etag
  from private.family_ops_calendar_mirrors
  where household_id=v_household and projection_key='special:'||v_task_delete::text;
  if v_claim_calendar_connection is null or nullif(v_provider_event_id,'') is null
     or nullif(v_provider_etag,'') is null then
    raise exception 'FAIL remediation DD8 B: completed provider identity was not retained';
  end if;

  insert into private.family_ops_calendar_target_deletions(
    household_id,calendar_connection_id,projection_key,provider_event_id,sync_state,ownership_transfer_state
  ) values (
    v_household,v_claim_calendar_connection,'special:'||v_task_delete::text,
    v_provider_event_id,'pending','delete_owned'
  );

  update private.family_ops_calendar_mirrors
  set lease_until=now()-interval '1 second'
  where household_id=v_household and projection_key='special:'||v_task_delete::text;
  v_transfer:=private.fn_transfer_task_mirror_to_family_event_v1(
    v_household,v_owner,v_owner_ref,'20000000-0000-0000-0000-000000000152',
    v_event_delete,v_claim_calendar_connection,'special:'||v_task_delete::text,
    v_provider_event_id,v_provider_etag,jsonb_build_object('title','DD8 DELETE family event'),
    now(),'family_ops_owned'
  );
  v_auth:=public.server_tx_authorize_family_ops_calendar_mirror(
    v_household,'special:'||v_task_delete::text,v_lease,v_claim_calendar_connection,v_provider_event_id
  );
  if coalesce((v_auth->>'authorized')::boolean,false) then
    raise exception 'FAIL remediation DD8 B: stale DELETE worker retained provider authorization';
  end if;
  if exists(
    select 1 from private.family_ops_calendar_target_deletions
    where household_id=v_household and calendar_connection_id=v_claim_calendar_connection
      and provider_event_id=v_provider_event_id
      and ownership_transfer_state='delete_owned'
      and sync_state in ('pending','failed','processing')
  ) then raise exception 'FAIL remediation DD8 B: target deletion ownership overlapped transfer'; end if;
  if exists(
    select 1 from private.canonical_google_provider_owner_audit_v1()
    where household_id=v_household and active_owner_count>1
  ) then raise exception 'FAIL remediation DD8: provider active_owner_count exceeded one'; end if;

  -- -----------------------------------------------------------------------
  -- DD9: structural allowlists and bounded typed values, not keyword-only.
  -- -----------------------------------------------------------------------
  perform private.fn_validate_nursery_provider_metadata_v2(jsonb_build_object('provider','test'));
  begin
    perform private.fn_validate_nursery_provider_metadata_v2(
      jsonb_build_object('provider','test','arbitrary_profile',jsonb_build_object('name','第三者'))
    );
    raise exception 'FAIL remediation DD9: arbitrary provider metadata was durable';
  exception when others then
    if sqlerrm like 'FAIL remediation%' then raise; end if;
  end;
  perform private.fn_validate_nursery_school_context_candidate_v2(
    jsonb_build_object('child_school_context_id','20000000-0000-0000-0000-000000000050')
  );
  begin
    perform private.fn_validate_nursery_school_context_candidate_v2(
      jsonb_build_object('other_child_name','第三者児童')
    );
    raise exception 'FAIL remediation DD9: third-party school-context field was durable';
  exception when others then
    if sqlerrm like 'FAIL remediation%' then raise; end if;
  end;
  perform private.fn_validate_nursery_fact_value_v2(
    'required_item',jsonb_build_object('item','エプロン')
  );
  begin
    perform private.fn_validate_nursery_fact_value_v2(
      'required_item',jsonb_build_object('paragraph','児童一覧の全文')
    );
    raise exception 'FAIL remediation DD9: arbitrary full-text fact shape was durable';
  exception when others then
    if sqlerrm like 'FAIL remediation%' then raise; end if;
  end;
  perform private.fn_validate_nursery_fact_value_v2(
    'url',jsonb_build_object('url','https://example.test/notice')
  );
  begin
    perform private.fn_validate_nursery_fact_value_v2(
      'url',jsonb_build_object('url','file:///private/notice')
    );
    raise exception 'FAIL remediation DD9: non-http URL scheme was accepted';
  exception when others then
    if sqlerrm like 'FAIL remediation%' then raise; end if;
  end;
  perform private.fn_validate_nursery_ai_patch_v2(
    'task',jsonb_build_object('title','前夜に準備')
  );
  begin
    perform private.fn_validate_nursery_ai_patch_v2(
      'task',jsonb_build_object('contact','third-party@example.test')
    );
    raise exception 'FAIL remediation DD9: arbitrary third-party profile/contact patch was durable';
  exception when others then
    if sqlerrm like 'FAIL remediation%' then raise; end if;
  end;

  -- -----------------------------------------------------------------------
  -- DD10: response-lost retry with the SAME operation replays after archive;
  -- a DIFFERENT operation remains a new mutation and is rejected.
  -- -----------------------------------------------------------------------
  v_sim:=private.fn_command_open_test_simulation_v1(
    v_household,v_owner,v_owner_ref,'20000000-0000-0000-0000-000000000153',
    'mama','archive retry regression'
  );
  v_test_context:=(v_sim->>'test_context_id')::uuid;
  v_archive_first:=private.fn_command_archive_test_simulation_v1(
    v_household,v_owner,v_owner_ref,v_test_context,1,
    '20000000-0000-0000-0000-000000000154'
  );
  v_archive_retry:=private.fn_command_archive_test_simulation_v1(
    v_household,v_owner,v_owner_ref,v_test_context,1,
    '20000000-0000-0000-0000-000000000154'
  );
  if v_archive_retry is distinct from v_archive_first
     or v_archive_retry->>'status'<>'archived' then
    raise exception 'FAIL remediation DD10: same archive operation did not replay prior result';
  end if;
  begin
    perform private.fn_command_archive_test_simulation_v1(
      v_household,v_owner,v_owner_ref,v_test_context,2,
      '20000000-0000-0000-0000-000000000155'
    );
    raise exception 'FAIL remediation DD10: different archive operation mutated archived context';
  exception when others then
    v_error:=sqlerrm;
    if v_error not like '%TEST_CONTEXT_NOT_ACTIVE%' then raise; end if;
  end;
end;
$$;
reset role;
select '50_source_review_remediation: PASS' as result;
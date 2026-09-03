-- Independent re-review HIGH remediation regression.
-- DD8: an authorized provider call remains a durable owner/fence after the
-- ordinary worker lease expires. If its result becomes uncertain, logical
-- ownership transfer is forbidden until a provider-side conditional PATCH
-- writes a unique handoff token and advances the Google ETag. Cover both Task
-- mirror and target-deletion paths.
-- DD9: allowed input free text is minimized before durable structured storage,
-- including a 64-fact split attempt.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid:='52000000-0000-0000-0000-000000000001';
  v_household uuid; v_owner_ref uuid; v_google_connection uuid; v_calendar_connection uuid;
  v_task uuid; v_event uuid; v_claim jsonb; v_auth jsonb; v_lease uuid; v_transfer jsonb;
  v_task2 uuid; v_event2 uuid; v_delete_id uuid; v_delete_claim jsonb; v_delete_lease uuid;
  v_handoff jsonb; v_confirm jsonb; v_handoff_token uuid; v_provider_snapshot jsonb;
  v_child uuid; v_context uuid; v_intake jsonb; v_extraction uuid; v_review jsonb; v_facts jsonb;
  v_error text;
begin
  insert into auth.users(id) values(v_owner) on conflict do nothing;
  insert into public.profiles(user_id,display_name) values(v_owner,'Rereview owner') on conflict do nothing;
  v_household:=(public.server_tx_create_household(
    v_owner,'52000000-0000-0000-0000-000000000010','Rereview household','Asia/Tokyo'
  )->>'household_id')::uuid;
  select id into v_owner_ref from public.domain_actor_refs
  where household_id=v_household and actor_kind='real_user' and real_user_id=v_owner;

  insert into private.google_connections(
    household_id,owner_user_id,google_subject,encrypted_refresh_token,encryption_version,scopes,status
  ) values (
    v_household,v_owner,'rereview-google','cipher',1,
    array['https://www.googleapis.com/auth/calendar.events'],'active'
  ) returning id into v_google_connection;
  insert into public.calendar_connections(
    household_id,provider,external_calendar_id,google_connection_id,active,reauth_required,is_family_write_target
  ) values (
    v_household,'google','rereview@example.test',v_google_connection,true,false,true
  ) returning id into v_calendar_connection;

  -- ----------------------------------------------------------------------
  -- DD8 A: Task mirror provider call remains fenced after worker lease expiry.
  -- Keep the Task hidden so the production enqueue trigger does not create the
  -- mirror for this fixture; the test constructs the exact provider state.
  -- ----------------------------------------------------------------------
  insert into public.task_instances(
    household_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,
    completion_mode,status,source,created_by,calendar_visibility
  ) values (
    v_household,'manual','DD8 inflight task','school','anytime','2030-04-01',
    v_owner,v_owner_ref,'person','manual','whole','todo','test',v_owner,'hidden'
  ) returning id into v_task;
  insert into private.family_ops_calendar_mirrors(
    household_id,projection_key,kind,local_date,task_instance_id,calendar_connection_id,
    provider_event_id,provider_etag,desired_action,sync_state,next_attempt_at,ownership_transfer_state
  ) values (
    v_household,'special:'||v_task::text,'special','2030-04-01',v_task,v_calendar_connection,
    'rereview-inflight-task','etag-task','upsert','pending','1800-01-01','task_owned'
  );
  v_claim:=public.server_tx_claim_family_ops_calendar_mirror('rereview-task-worker',30);
  if v_claim is null or v_claim->>'projection_key'<>'special:'||v_task::text then
    raise exception 'FAIL rereview DD8: Task mirror not claimed: %',v_claim;
  end if;
  v_lease:=(v_claim->>'lease_token')::uuid;
  v_auth:=public.server_tx_authorize_family_ops_calendar_mirror(
    v_household,'special:'||v_task::text,v_lease,v_calendar_connection,'rereview-inflight-task'
  );
  if coalesce((v_auth->>'authorized')::boolean,false) is not true
     or nullif(v_auth->>'mutation_fence_id','') is null
     or nullif(v_auth->>'request_deadline_at','') is null then
    raise exception 'FAIL rereview DD8: Task provider mutation fence not established: %',v_auth;
  end if;
  if not exists(select 1 from private.google_provider_mutation_fences
    where id=(v_auth->>'mutation_fence_id')::uuid and state='inflight') then
    raise exception 'FAIL rereview DD8: durable Task inflight row missing';
  end if;

  insert into public.family_events(
    household_id,title,all_day,starts_at,ends_at,calendar_sync_preference,created_by_actor_ref_id
  ) values (
    v_household,'DD8 inflight family event',false,
    '2030-04-01 09:00+09','2030-04-01 10:00+09','family_ops_owned',v_owner_ref
  ) returning id into v_event;
  update private.family_ops_calendar_mirrors set lease_until=now()-interval '1 second'
  where household_id=v_household and projection_key='special:'||v_task::text;

  begin
    perform private.fn_transfer_task_mirror_to_family_event_v1(
      v_household,v_owner,v_owner_ref,'52000000-0000-0000-0000-000000000101',
      v_event,v_calendar_connection,'special:'||v_task::text,'rereview-inflight-task','etag-task',
      jsonb_build_object('title','DD8 inflight family event'),now(),'family_ops_owned'
    );
    raise exception 'FAIL rereview DD8: expired worker lease bypassed live provider-call fence';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL rereview%' then raise; end if;
    if v_error not like '%PROVIDER_MUTATION_INFLIGHT%' then raise; end if;
  end;

  update private.google_provider_mutation_fences
  set request_deadline_at=now()-interval '1 second'
  where id=(v_auth->>'mutation_fence_id')::uuid;
  perform private.fn_mark_provider_mutation_fence_expired_v1(v_calendar_connection,'rereview-inflight-task');
  if not exists(select 1 from private.google_provider_mutation_fences
    where id=(v_auth->>'mutation_fence_id')::uuid and state='uncertain') then
    raise exception 'FAIL rereview DD8: expired provider call was not marked uncertain';
  end if;

  -- A later GET or elapsed quarantine alone is not sufficient anymore.
  begin
    perform private.fn_transfer_task_mirror_to_family_event_v1(
      v_household,v_owner,v_owner_ref,'52000000-0000-0000-0000-000000000102',
      v_event,v_calendar_connection,'special:'||v_task::text,'rereview-inflight-task','etag-task',
      jsonb_build_object('id','rereview-inflight-task'),now(),'family_ops_owned'
    );
    raise exception 'FAIL rereview DD8: uncertain provider call transferred without provider handoff fence';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL rereview%' then raise; end if;
    if v_error not like '%PROVIDER_HANDOFF_FENCE_REQUIRED%' then raise; end if;
  end;

  v_handoff:=public.server_tx_prepare_google_provider_handoff_fence(
    v_household,v_calendar_connection,'special:'||v_task::text,'rereview-inflight-task'
  );
  if coalesce((v_handoff->>'required')::boolean,false) is not true
     or v_handoff->>'state'<>'prepared'
     or nullif(v_handoff->>'handoff_token','') is null then
    raise exception 'FAIL rereview DD8: Task handoff fence was not prepared: %',v_handoff;
  end if;
  v_handoff_token:=(v_handoff->>'handoff_token')::uuid;
  v_provider_snapshot:=jsonb_build_object(
    'id','rereview-inflight-task',
    'extendedProperties',jsonb_build_object(
      'private',jsonb_build_object('familyOpsOwnershipFenceToken',v_handoff_token::text)
    )
  );
  v_confirm:=public.server_tx_confirm_google_provider_handoff_fence(
    v_handoff_token,'etag-task','etag-task-fenced',v_provider_snapshot
  );
  if coalesce((v_confirm->>'confirmed')::boolean,false) is not true
     or v_confirm->>'state'<>'provider_fenced'
     or v_confirm->>'provider_etag'<>'etag-task-fenced' then
    raise exception 'FAIL rereview DD8: Task provider handoff confirmation failed: %',v_confirm;
  end if;

  v_transfer:=private.fn_transfer_task_mirror_to_family_event_v1(
    v_household,v_owner,v_owner_ref,'52000000-0000-0000-0000-000000000103',
    v_event,v_calendar_connection,'special:'||v_task::text,'rereview-inflight-task','etag-task-fenced',
    v_provider_snapshot,now(),'family_ops_owned'
  );
  if v_transfer->>'ownership_transfer_state'<>'validated'
     or v_transfer->>'provider_handoff_fenced'<>'true'
     or not exists(select 1 from private.google_provider_mutation_fences
       where id=(v_auth->>'mutation_fence_id')::uuid and state='reconciled'
         and revalidated_at is not null and revalidated_etag='etag-task-fenced')
     or not exists(select 1 from private.google_provider_handoff_fences
       where handoff_token=v_handoff_token and state='consumed' and consumed_at is not null) then
    raise exception 'FAIL rereview DD8: Task provider-side handoff fence was not consumed correctly';
  end if;

  -- ----------------------------------------------------------------------
  -- DD8 B: same durable/provider-side fence applies to target deletion.
  -- ----------------------------------------------------------------------
  insert into public.task_instances(
    household_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,
    completion_mode,status,source,created_by,calendar_visibility
  ) values (
    v_household,'manual','DD8 deletion inflight','school','anytime','2030-04-02',
    v_owner,v_owner_ref,'person','manual','whole','todo','test',v_owner,'hidden'
  ) returning id into v_task2;
  insert into private.family_ops_calendar_mirrors(
    household_id,projection_key,kind,local_date,task_instance_id,calendar_connection_id,
    provider_event_id,provider_etag,desired_action,sync_state,ownership_transfer_state
  ) values (
    v_household,'special:'||v_task2::text,'special','2030-04-02',v_task2,v_calendar_connection,
    'rereview-inflight-delete','etag-delete','upsert','synced','task_owned'
  );
  insert into private.family_ops_calendar_target_deletions(
    household_id,calendar_connection_id,projection_key,provider_event_id,sync_state,next_attempt_at,ownership_transfer_state
  ) values (
    v_household,v_calendar_connection,'special:'||v_task2::text,'rereview-inflight-delete',
    'pending','1800-01-01','delete_owned'
  ) returning id into v_delete_id;
  v_delete_claim:=public.server_tx_claim_family_ops_calendar_target_deletion('rereview-delete-worker',30);
  if v_delete_claim is null or (v_delete_claim->>'id')::uuid<>v_delete_id then
    raise exception 'FAIL rereview DD8: target deletion not claimed: %',v_delete_claim;
  end if;
  v_delete_lease:=(v_delete_claim->>'lease_token')::uuid;
  v_auth:=public.server_tx_authorize_family_ops_calendar_target_deletion(v_delete_id,v_delete_lease);
  if coalesce((v_auth->>'authorized')::boolean,false) is not true
     or nullif(v_auth->>'mutation_fence_id','') is null then
    raise exception 'FAIL rereview DD8: target deletion fence not established: %',v_auth;
  end if;
  insert into public.family_events(
    household_id,title,all_day,starts_at,ends_at,calendar_sync_preference,created_by_actor_ref_id
  ) values (
    v_household,'DD8 deletion family event',false,
    '2030-04-02 09:00+09','2030-04-02 10:00+09','family_ops_owned',v_owner_ref
  ) returning id into v_event2;
  update private.family_ops_calendar_target_deletions set lease_until=now()-interval '1 second'
  where id=v_delete_id;

  begin
    perform private.fn_transfer_task_mirror_to_family_event_v1(
      v_household,v_owner,v_owner_ref,'52000000-0000-0000-0000-000000000104',
      v_event2,v_calendar_connection,'special:'||v_task2::text,'rereview-inflight-delete','etag-delete',
      jsonb_build_object('id','rereview-inflight-delete'),now(),'family_ops_owned'
    );
    raise exception 'FAIL rereview DD8: target deletion inflight call did not block transfer';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL rereview%' then raise; end if;
    if v_error not like '%PROVIDER_MUTATION_INFLIGHT%' then raise; end if;
  end;

  update private.google_provider_mutation_fences
  set request_deadline_at=now()-interval '2 minutes'
  where id=(v_auth->>'mutation_fence_id')::uuid;
  perform private.fn_mark_provider_mutation_fence_expired_v1(v_calendar_connection,'rereview-inflight-delete');
  begin
    perform private.fn_transfer_task_mirror_to_family_event_v1(
      v_household,v_owner,v_owner_ref,'52000000-0000-0000-0000-000000000105',
      v_event2,v_calendar_connection,'special:'||v_task2::text,'rereview-inflight-delete','etag-delete',
      jsonb_build_object('id','rereview-inflight-delete'),now(),'family_ops_owned'
    );
    raise exception 'FAIL rereview DD8: uncertain target deletion transferred without provider handoff fence';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL rereview%' then raise; end if;
    if v_error not like '%PROVIDER_HANDOFF_FENCE_REQUIRED%' then raise; end if;
  end;

  v_handoff:=public.server_tx_prepare_google_provider_handoff_fence(
    v_household,v_calendar_connection,'special:'||v_task2::text,'rereview-inflight-delete'
  );
  if coalesce((v_handoff->>'required')::boolean,false) is not true
     or v_handoff->>'state'<>'prepared'
     or nullif(v_handoff->>'handoff_token','') is null then
    raise exception 'FAIL rereview DD8: deletion handoff fence was not prepared: %',v_handoff;
  end if;
  v_handoff_token:=(v_handoff->>'handoff_token')::uuid;
  v_provider_snapshot:=jsonb_build_object(
    'id','rereview-inflight-delete',
    'extendedProperties',jsonb_build_object(
      'private',jsonb_build_object('familyOpsOwnershipFenceToken',v_handoff_token::text)
    )
  );
  v_confirm:=public.server_tx_confirm_google_provider_handoff_fence(
    v_handoff_token,'etag-delete','etag-delete-fenced',v_provider_snapshot
  );
  if coalesce((v_confirm->>'confirmed')::boolean,false) is not true
     or v_confirm->>'state'<>'provider_fenced'
     or v_confirm->>'provider_etag'<>'etag-delete-fenced' then
    raise exception 'FAIL rereview DD8: deletion provider handoff confirmation failed: %',v_confirm;
  end if;

  v_transfer:=private.fn_transfer_task_mirror_to_family_event_v1(
    v_household,v_owner,v_owner_ref,'52000000-0000-0000-0000-000000000106',
    v_event2,v_calendar_connection,'special:'||v_task2::text,'rereview-inflight-delete','etag-delete-fenced',
    v_provider_snapshot,now(),'family_ops_owned'
  );
  if v_transfer->>'ownership_transfer_state'<>'validated'
     or v_transfer->>'provider_handoff_fenced'<>'true'
     or not exists(select 1 from private.google_provider_mutation_fences
       where id=(v_auth->>'mutation_fence_id')::uuid and state='reconciled'
         and revalidated_at is not null and revalidated_etag='etag-delete-fenced')
     or not exists(select 1 from private.google_provider_handoff_fences
       where handoff_token=v_handoff_token and state='consumed' and consumed_at is not null) then
    raise exception 'FAIL rereview DD8: deletion provider-side handoff fence was not consumed correctly';
  end if;

  if exists(select 1 from private.google_provider_mutation_fences where state in ('inflight','uncertain')) then
    raise exception 'FAIL rereview DD8: unresolved provider mutation fence leaked from regression';
  end if;
  if exists(select 1 from private.google_provider_handoff_fences where state in ('prepared','provider_fenced')) then
    raise exception 'FAIL rereview DD8: unconsumed provider handoff fence leaked from regression';
  end if;

  -- ----------------------------------------------------------------------
  -- DD9: free text may be submitted to the review pipeline, but it must not
  -- become durable structured data before a human confirms a target command.
  -- ----------------------------------------------------------------------
  insert into public.family_children(household_id,display_name)
  values(v_household,'DD9 target child') returning id into v_child;
  insert into public.child_school_contexts(
    household_id,child_id,school_display_name,class_display_name,effective_from,recognition_aliases
  ) values (
    v_household,v_child,'DD9 school','ひかり組','2030-01-01',array['ひかり組']
  ) returning id into v_context;

  v_intake:=private.fn_command_create_nursery_intake_v1(
    v_household,v_owner,v_owner_ref,null,'52000000-0000-0000-0000-000000000201',
    'codmon_notice','private/dd9/rereview-object','2030-04-03 09:00+09','rereview-v1',
    jsonb_build_object('provider','test','model','A組山田花子09011112222'),'pwa'
  );
  v_extraction:=(v_intake->>'extraction_id')::uuid;
  if exists(select 1 from private.document_extractions
    where id=v_extraction and provider_metadata::text like '%山田花子%')
     or not exists(select 1 from private.document_extractions
       where id=v_extraction and provider_metadata ? 'model_fingerprint') then
    raise exception 'FAIL rereview DD9: provider metadata free text survived minimization';
  end if;

  select jsonb_agg(jsonb_build_object(
    'child_school_context_id',v_context,
    'fact_kind','required_item',
    'normalized_value',jsonb_build_object(
      'item','エプロン',
      'note','A組 山田花子 090-1111-2222 roster fragment #'||g::text
    ),
    'confidence_band','high',
    'source_locator','A組 山田花子 line #'||g::text
  )) into v_facts
  from generate_series(1,64) g;

  v_review:=private.fn_command_record_nursery_extraction_v1(
    v_household,v_owner,v_owner_ref,null,'52000000-0000-0000-0000-000000000202',v_extraction,1,
    jsonb_build_object(
      'child_school_context_id',v_context,
      'school_display_name','A組 山田花子 090-1111-2222',
      'class_display_name','roster fragment'
    ),
    v_facts,
    jsonb_build_array(jsonb_build_object(
      'child_school_context_id',v_context,
      'target_type','task',
      'proposed_patch',jsonb_build_object(
        'title','山田花子さんへ連絡',
        'notes','third-party@example.test / 090-1111-2222 / class roster'
      ),
      'explanation','A組の第三者プロフィールと連絡先を候補説明に保存'
    )),
    'pwa'
  );
  if (v_review->>'source_fact_count')::integer<>64
     or (v_review->>'ai_candidate_count')::integer<>1 then
    raise exception 'FAIL rereview DD9: adversarial minimized payload did not reach review boundary: %',v_review;
  end if;

  if exists(select 1 from private.document_facts
    where extraction_id=v_extraction
      and (normalized_value::text like '%山田花子%'
        or normalized_value::text like '%090-1111-2222%'
        or normalized_value ? 'note'
        or source_locator is not null)) then
    raise exception 'FAIL rereview DD9: roster/contact text became durable document fact';
  end if;
  if exists(select 1 from private.document_facts
    where extraction_id=v_extraction
      and normalized_value->>'item_code'<>'apron') then
    raise exception 'FAIL rereview DD9: controlled item code minimization failed';
  end if;
  if exists(select 1 from public.change_candidates
    where source_ref=v_extraction::text
      and (proposed_patch::text like '%山田花子%'
        or proposed_patch::text like '%090-1111-2222%'
        or proposed_patch::text like '%third-party@example.test%'
        or proposed_patch ? 'title'
        or proposed_patch ? 'notes'
        or proposed_patch ? 'explanation')) then
    raise exception 'FAIL rereview DD9: free-text AI candidate data became durable';
  end if;
  if not exists(select 1 from public.change_candidates
    where source_ref=v_extraction::text
      and proposed_patch->>'reason_code'='model_candidate_requires_review'
      and proposed_patch->>'origin_label'='ai_inference') then
    raise exception 'FAIL rereview DD9: controlled AI review marker missing';
  end if;
  if exists(select 1 from private.document_extractions
    where id=v_extraction
      and (school_context_candidate ? 'school_display_name'
        or school_context_candidate ? 'class_display_name'
        or school_context_candidate::text like '%山田花子%')) then
    raise exception 'FAIL rereview DD9: school-context free text became durable';
  end if;
end;
$$;

reset role;
select '52_independent_rereview_high_remediation: PASS' as result;
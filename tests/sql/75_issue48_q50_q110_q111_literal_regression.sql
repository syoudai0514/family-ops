-- Issue #48 independent review remediation — direct literal regressions.
-- Q50: protected individual transport agreements require BOTH users to answer.
-- Q110: accepted Google schedule changes create reviewable linked-prep changes,
--       never silently moving completed or incomplete prep.
-- Q111: Google deletion exposes three distinct durable outcomes.
\set ON_ERROR_STOP on
set role service_role;

-- ---------------------------------------------------------------------------
-- Q50 — both-party keep/review confirmation, Q51 disagreement transition.
-- ---------------------------------------------------------------------------
do $$
declare
  u1 uuid:=gen_random_uuid(); u2 uuid:=gen_random_uuid(); u3 uuid:=gen_random_uuid();
  h1 uuid; h2 uuid; token text; actor1 uuid; actor2 uuid;
  days_a jsonb; days_b jsonb; days_c jsonb;
  r jsonb; r_first jsonb; r_second jsonb; r_keep1 jsonb; r_keep2 jsonb;
  protected1 uuid; protected2 uuid; group1 uuid; group2 uuid; rev bigint; failed boolean:=false;
begin
  insert into auth.users(id) values(u1),(u2),(u3);
  insert into public.profiles(user_id,display_name) values(u1,'Q50 Papa'),(u2,'Q50 Mama'),(u3,'Q50 Other');
  h1:=(public.server_tx_create_household(u1,gen_random_uuid(),'Q50 H1','Papa')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(u1,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(u2,gen_random_uuid(),token,'Mama');
  h2:=(public.server_tx_create_household(u3,gen_random_uuid(),'Q50 H2','Other')->>'household_id')::uuid;
  select id into actor1 from public.domain_actor_refs where household_id=h1 and actor_kind='real_user' and real_user_id=u1;
  select id into actor2 from public.domain_actor_refs where household_id=h1 and actor_kind='real_user' and real_user_id=u2;

  days_a:=(select jsonb_agg(jsonb_build_object(
    'weekday',d,'dropoff_user_id',u1,'pickup_user_id',u2,
    'dropoff_local_time','08:00','pickup_local_time','17:30') order by d)
    from generate_series(1,7)d);
  days_b:=(select jsonb_agg(jsonb_build_object(
    'weekday',d,'dropoff_user_id',u2,'pickup_user_id',u1,
    'dropoff_local_time','08:10','pickup_local_time','17:40') order by d)
    from generate_series(1,7)d);
  days_c:=(select jsonb_agg(jsonb_build_object(
    'weekday',d,'dropoff_user_id',u1,'pickup_user_id',u2,
    'dropoff_local_time','08:20','pickup_local_time','17:50') order by d)
    from generate_series(1,7)d);

  perform public.server_tx_save_transport_template_v2(u1,gen_random_uuid(),'2026-09-01',days_a);
  select ti.id into protected1
  from public.task_instances ti join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id
  where ti.household_id=h1 and td.code='dropoff' and ti.scheduled_date='2026-10-05';
  if protected1 is null then raise exception 'FAIL Q50: protected occurrence fixture missing'; end if;
  update public.task_instances set planned_assignee_id=u2,planned_assignee_actor_ref_id=actor2,
    assignment_mode='person',assignment_source='agreement',revision=revision+1 where id=protected1;

  r:=public.server_tx_save_transport_template_v2(u1,gen_random_uuid(),'2026-10-01',days_b);
  if coalesce((r->>'confirmation_required')::boolean,false) is not true or nullif(r->>'conflict_review_group_id','') is null then
    raise exception 'FAIL Q50: template change did not create both-party review: %',r;
  end if;
  group1:=(r->>'conflict_review_group_id')::uuid;
  if not exists(select 1 from public.task_instances where id=protected1 and planned_assignee_id=u2 and assignment_source='agreement') then
    raise exception 'FAIL Q50: template change overwrote individual agreement before confirmation';
  end if;
  if (select count(*) from public.user_notifications where household_id=h1 and type='transport_conflict_review' and payload->>'review_group_id'=group1::text)<>2 then
    raise exception 'FAIL Q50: both users were not asked to confirm protected agreement';
  end if;

  -- Another household cannot answer this family's review.
  rev:=(select revision from public.transport_conflict_review_groups where id=group1);
  begin
    perform public.server_tx_respond_transport_conflict_review(u3,gen_random_uuid(),group1,rev,'keep');
  exception when others then failed:=position('TRANSPORT_REVIEW_NOT_FOUND' in sqlerrm)>0; end;
  if not failed then raise exception 'FAIL Q50: cross-household review response succeeded'; end if;

  -- First response says review: MUST remain pending until the second user answers.
  r_first:=public.server_tx_respond_transport_conflict_review(u1,gen_random_uuid(),group1,rev,'review');
  if r_first->>'status'<>'pending' or (r_first->>'responses')::int<>1 or (r_first->>'required_responses')::int<>2 then
    raise exception 'FAIL Q50: first response prematurely resolved group: %',r_first;
  end if;
  if not exists(select 1 from public.task_instances where id=protected1 and planned_assignee_id=u2 and assignment_source='agreement') then
    raise exception 'FAIL Q50/Q51: first disagreement mutated original agreement';
  end if;

  -- Once both have answered, disagreement enters Q51 adjustment while preserving truth.
  r_second:=public.server_tx_respond_transport_conflict_review(
    u2,gen_random_uuid(),group1,(r_first->>'revision')::bigint,'keep');
  if r_second->>'status'<>'needs_review' or r_second->>'q51_state'<>'担当調整中' then
    raise exception 'FAIL Q50/Q51: disagreement did not enter adjustment state: %',r_second;
  end if;
  if not exists(select 1 from public.task_instances where id=protected1 and planned_assignee_id=u2 and assignment_source='agreement') then
    raise exception 'FAIL Q50/Q51: disagreement overwrote original agreement';
  end if;
  if (select count(*) from public.user_notifications where household_id=h1 and type='transport_conflict_adjusting' and payload->>'review_group_id'=group1::text)<>2 then
    raise exception 'FAIL Q50/Q51: both users were not notified of adjustment-in-progress';
  end if;

  -- A second protected range proves the all-keep path.
  select ti.id into protected2
  from public.task_instances ti join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id
  where ti.household_id=h1 and td.code='dropoff' and ti.scheduled_date='2026-10-12';
  if protected2 is null then raise exception 'FAIL Q50: second protected occurrence fixture missing'; end if;
  update public.task_instances set planned_assignee_id=u1,planned_assignee_actor_ref_id=actor1,
    assignment_mode='person',assignment_source='agreement',revision=revision+1 where id=protected2;
  r:=public.server_tx_save_transport_template_v2(u1,gen_random_uuid(),'2026-10-08',days_c);
  group2:=nullif(r->>'conflict_review_group_id','')::uuid;
  if group2 is null then raise exception 'FAIL Q50: second review group missing'; end if;
  rev:=(select revision from public.transport_conflict_review_groups where id=group2);
  r_keep1:=public.server_tx_respond_transport_conflict_review(u1,gen_random_uuid(),group2,rev,'keep');
  if r_keep1->>'status'<>'pending' then raise exception 'FAIL Q50: one keep resolved before both answers'; end if;
  r_keep2:=public.server_tx_respond_transport_conflict_review(u2,gen_random_uuid(),group2,(r_keep1->>'revision')::bigint,'keep');
  if r_keep2->>'status'<>'kept' then raise exception 'FAIL Q50: both keep did not resolve as kept: %',r_keep2; end if;
  if not exists(select 1 from public.task_instances where id=protected2 and planned_assignee_id=u1 and assignment_source='agreement') then
    raise exception 'FAIL Q50: both-keep path rewrote protected agreement';
  end if;
  if h2 is null then raise exception 'FAIL Q50 fixture'; end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Q110 — Google schedule acceptance + linked preparation change candidate.
-- ---------------------------------------------------------------------------
do $$
declare
  owner_id uuid:=gen_random_uuid(); other_id uuid:=gen_random_uuid();
  hh uuid; hh2 uuid; actor_ref uuid; gc uuid; cal uuid; ev uuid;
  prep_open uuid; prep_done uuid; review public.google_event_review_candidates%rowtype;
  prep_review public.event_preparation_change_candidates%rowtype; failed boolean:=false;
  old_start timestamptz:='2026-10-20 10:00+09'; new_start timestamptz:='2026-10-21 11:00+09';
begin
  insert into auth.users(id) values(owner_id),(other_id);
  insert into public.profiles(user_id,display_name) values(owner_id,'Q110 Owner'),(other_id,'Q110 Other');
  hh:=(public.server_tx_create_household(owner_id,gen_random_uuid(),'Q110 H1','Asia/Tokyo')->>'household_id')::uuid;
  hh2:=(public.server_tx_create_household(other_id,gen_random_uuid(),'Q110 H2','Asia/Tokyo')->>'household_id')::uuid;
  select id into actor_ref from public.domain_actor_refs where household_id=hh and actor_kind='real_user' and real_user_id=owner_id;
  insert into private.google_connections(household_id,owner_user_id,google_subject,encrypted_refresh_token,encryption_version,scopes,status)
    values(hh,owner_id,'q110-google','cipher',1,array['https://www.googleapis.com/auth/calendar.events'],'active') returning id into gc;
  insert into public.calendar_connections(household_id,provider,external_calendar_id,google_connection_id,active,reauth_required)
    values(hh,'google','q110@example.invalid',gc,true,false) returning id into cal;
  insert into public.family_events(household_id,title,status,all_day,starts_at,ends_at,calendar_sync_preference,created_by_actor_ref_id)
    values(hh,'面談','active',false,old_start,old_start+interval '30 minutes','external_follow',actor_ref) returning id into ev;
  insert into public.family_event_field_authorities(household_id,family_event_id,field_name,authority_mode) values
    (hh,ev,'title','human_protected'),(hh,ev,'schedule','human_protected'),(hh,ev,'location','human_protected');
  insert into public.family_event_external_links(household_id,family_event_id,provider,calendar_connection_id,google_event_id,link_mode,last_external_etag,last_reconciled_at,writer_enabled,ownership_transfer_state)
    values(hh,ev,'google',cal,'q110-event','external_follow','etag-1',now(),false,'inactive');
  insert into public.calendar_events_cache(household_id,calendar_connection_id,google_event_id,title,starts_at,ends_at,status,etag)
    values(hh,cal,'q110-event','面談',old_start,old_start+interval '30 minutes','confirmed','etag-1');

  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,due_at,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by,event_id)
    values(hh,'manual','面談の持ち物','prep','anytime','2026-10-19','2026-10-19 20:00+09',owner_id,actor_ref,'person','manual','whole','todo','manual',owner_id,ev)
    returning id into prep_open;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,due_at,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by,event_id)
    values(hh,'manual','提出済み書類','prep','anytime','2026-10-18','2026-10-18 20:00+09',owner_id,actor_ref,'person','manual','whole','todo','manual',owner_id,ev)
    returning id into prep_done;
  perform public.server_tx_complete_task(owner_id,gen_random_uuid(),prep_done,'self',true,'pwa');

  update public.calendar_events_cache set starts_at=new_start,ends_at=new_start+interval '30 minutes',etag='etag-2'
    where calendar_connection_id=cal and google_event_id='q110-event';
  select * into review from public.google_event_review_candidates
    where family_event_id=ev and candidate_kind='protected_change' and status='pending' order by created_at desc limit 1;
  if not found or not ('schedule'=any(review.changed_fields)) then raise exception 'FAIL Q110: Google schedule diff missing'; end if;
  perform public.server_tx_resolve_google_event_review(owner_id,gen_random_uuid(),review.id,review.revision,'accept_google');
  if (select starts_at from public.family_events where id=ev) is distinct from new_start then
    raise exception 'FAIL Q110: accepted Google schedule did not update event';
  end if;
  if (select scheduled_date from public.task_instances where id=prep_open)<>date '2026-10-19' then
    raise exception 'FAIL Q110: incomplete prep was silently auto-shifted';
  end if;
  if (select scheduled_date from public.task_instances where id=prep_done)<>date '2026-10-18' then
    raise exception 'FAIL Q110: completed prep actual was rewritten';
  end if;
  select * into prep_review from public.event_preparation_change_candidates
    where family_event_id=ev and task_instance_id=prep_open and status='pending';
  if not found or prep_review.old_scheduled_date<>date '2026-10-19' or prep_review.proposed_scheduled_date<>date '2026-10-20' then
    raise exception 'FAIL Q110: linked incomplete prep change candidate missing/wrong';
  end if;
  if exists(select 1 from public.event_preparation_change_candidates where family_event_id=ev and task_instance_id=prep_done) then
    raise exception 'FAIL Q110: completed prep received mutable schedule candidate';
  end if;

  begin
    perform public.server_tx_resolve_event_preparation_change(other_id,gen_random_uuid(),prep_review.id,prep_review.revision,'apply');
  exception when others then failed:=position('PREPARATION_REVIEW_NOT_FOUND' in sqlerrm)>0; end;
  if not failed then raise exception 'FAIL Q110: cross-household prep resolution succeeded'; end if;
  perform public.server_tx_resolve_event_preparation_change(owner_id,gen_random_uuid(),prep_review.id,prep_review.revision,'apply');
  if (select scheduled_date from public.task_instances where id=prep_open)<>date '2026-10-20' then
    raise exception 'FAIL Q110: explicit prep apply did not move linked prep';
  end if;
  if hh2 is null then raise exception 'FAIL Q110 fixture'; end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Q111 — literal three-way Google-deletion resolution.
-- ---------------------------------------------------------------------------
do $$
declare
  owner_id uuid:=gen_random_uuid(); hh uuid; actor_ref uuid; gc uuid; cal uuid;
  ev_cancel uuid; ev_wait uuid; ev_hide uuid; c public.google_event_review_candidates%rowtype;
  base_ts timestamptz:='2026-11-10 10:00+09';
begin
  insert into auth.users(id) values(owner_id);
  insert into public.profiles(user_id,display_name) values(owner_id,'Q111 Owner');
  hh:=(public.server_tx_create_household(owner_id,gen_random_uuid(),'Q111 H','Asia/Tokyo')->>'household_id')::uuid;
  select id into actor_ref from public.domain_actor_refs where household_id=hh and actor_kind='real_user' and real_user_id=owner_id;
  insert into private.google_connections(household_id,owner_user_id,google_subject,encrypted_refresh_token,encryption_version,scopes,status)
    values(hh,owner_id,'q111-google','cipher',1,array['https://www.googleapis.com/auth/calendar.events'],'active') returning id into gc;
  insert into public.calendar_connections(household_id,provider,external_calendar_id,google_connection_id,active,reauth_required)
    values(hh,'google','q111@example.invalid',gc,true,false) returning id into cal;

  insert into public.family_events(household_id,title,status,all_day,starts_at,ends_at,calendar_sync_preference,created_by_actor_ref_id) values
    (hh,'中止する予定','active',false,base_ts,base_ts+interval '30 minutes','external_follow',actor_ref) returning id into ev_cancel;
  insert into public.family_events(household_id,title,status,all_day,starts_at,ends_at,calendar_sync_preference,created_by_actor_ref_id) values
    (hh,'日程変更待ち予定','active',false,base_ts+interval '1 day',base_ts+interval '1 day 30 minutes','external_follow',actor_ref) returning id into ev_wait;
  insert into public.family_events(household_id,title,status,all_day,starts_at,ends_at,calendar_sync_preference,created_by_actor_ref_id) values
    (hh,'Googleのみ非表示予定','active',false,base_ts+interval '2 days',base_ts+interval '2 days 30 minutes','external_follow',actor_ref) returning id into ev_hide;

  insert into public.family_event_field_authorities(household_id,family_event_id,field_name,authority_mode)
  select hh,e.id,f,'human_protected' from (values(ev_cancel),(ev_wait),(ev_hide)) e(id)
  cross join (values('title'),('schedule'),('location')) x(f);
  insert into public.family_event_external_links(household_id,family_event_id,provider,calendar_connection_id,google_event_id,link_mode,last_external_etag,last_reconciled_at,writer_enabled,ownership_transfer_state) values
    (hh,ev_cancel,'google',cal,'q111-cancel','external_follow','e1',now(),false,'inactive'),
    (hh,ev_wait,'google',cal,'q111-wait','external_follow','e1',now(),false,'inactive'),
    (hh,ev_hide,'google',cal,'q111-hide','external_follow','e1',now(),false,'inactive');
  insert into public.calendar_events_cache(household_id,calendar_connection_id,google_event_id,title,starts_at,ends_at,status,etag) values
    (hh,cal,'q111-cancel','中止する予定',base_ts,base_ts+interval '30 minutes','confirmed','e1'),
    (hh,cal,'q111-wait','日程変更待ち予定',base_ts+interval '1 day',base_ts+interval '1 day 30 minutes','confirmed','e1'),
    (hh,cal,'q111-hide','Googleのみ非表示予定',base_ts+interval '2 days',base_ts+interval '2 days 30 minutes','confirmed','e1');

  update public.calendar_events_cache set status='cancelled',tombstone_kind='deleted',etag='e2' where calendar_connection_id=cal and google_event_id='q111-cancel';
  select * into c from public.google_event_review_candidates where family_event_id=ev_cancel and candidate_kind='google_deleted' and status='pending';
  if not found then raise exception 'FAIL Q111: cancel candidate missing'; end if;
  perform public.server_tx_resolve_google_event_review(owner_id,gen_random_uuid(),c.id,c.revision,'cancel_family');
  if (select status from public.family_events where id=ev_cancel)<>'cancelled' then raise exception 'FAIL Q111: cancel_family did not cancel Family Ops event'; end if;

  update public.calendar_events_cache set status='cancelled',tombstone_kind='deleted',etag='e2' where calendar_connection_id=cal and google_event_id='q111-wait';
  select * into c from public.google_event_review_candidates where family_event_id=ev_wait and candidate_kind='google_deleted' and status='pending';
  if not found then raise exception 'FAIL Q111: waiting candidate missing'; end if;
  perform public.server_tx_resolve_google_event_review(owner_id,gen_random_uuid(),c.id,c.revision,'waiting_reschedule');
  if (select status from public.family_events where id=ev_wait)<>'active'
     or (select schedule_review_state from public.family_events where id=ev_wait)<>'waiting_reschedule' then
    raise exception 'FAIL Q111: waiting_reschedule did not preserve event in waiting state';
  end if;
  if not exists(select 1 from public.family_event_external_links where family_event_id=ev_wait and google_event_id='q111-wait') then
    raise exception 'FAIL Q111: waiting_reschedule unexpectedly detached Google link';
  end if;

  update public.calendar_events_cache set status='cancelled',tombstone_kind='deleted',etag='e2' where calendar_connection_id=cal and google_event_id='q111-hide';
  select * into c from public.google_event_review_candidates where family_event_id=ev_hide and candidate_kind='google_deleted' and status='pending';
  if not found then raise exception 'FAIL Q111: google-only-hidden candidate missing'; end if;
  perform public.server_tx_resolve_google_event_review(owner_id,gen_random_uuid(),c.id,c.revision,'google_only_hidden');
  if (select status from public.family_events where id=ev_hide)<>'active'
     or (select schedule_review_state from public.family_events where id=ev_hide)<>'scheduled' then
    raise exception 'FAIL Q111: google_only_hidden changed Family Ops event truth';
  end if;
  if exists(select 1 from public.family_event_external_links where family_event_id=ev_hide and google_event_id='q111-hide') then
    raise exception 'FAIL Q111: google_only_hidden did not detach only the Google side';
  end if;
end;
$$;

reset role;
select '75_issue48_q50_q110_q111_literal_regression: PASS' as result;

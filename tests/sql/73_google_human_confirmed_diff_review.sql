-- Appendix A Q110-Q112 exact E2E.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid:=gen_random_uuid();
  v_other uuid:=gen_random_uuid();
  v_hh uuid;
  v_hh2 uuid;
  v_actor_ref uuid;
  v_google_conn uuid;
  v_cal uuid;
  v_event uuid;
  v_dup_event uuid;
  v_candidate public.google_event_review_candidates%rowtype;
  v_dup_candidate public.google_event_review_candidates%rowtype;
  v_result jsonb;
  v_failed boolean;
  v_original_start timestamptz:='2026-10-10 10:00+09';
  v_changed_start timestamptz:='2026-10-10 11:00+09';
begin
  insert into auth.users(id) values(v_owner),(v_other);
  insert into public.profiles(user_id,display_name) values(v_owner,'Google review owner'),(v_other,'Other owner');
  v_hh:=(public.server_tx_create_household(v_owner,gen_random_uuid(),'Google review H1','Asia/Tokyo')->>'household_id')::uuid;
  v_hh2:=(public.server_tx_create_household(v_other,gen_random_uuid(),'Google review H2','Asia/Tokyo')->>'household_id')::uuid;
  select id into v_actor_ref from public.domain_actor_refs
    where household_id=v_hh and actor_kind='real_user' and real_user_id=v_owner;

  insert into private.google_connections(
    household_id,owner_user_id,google_subject,encrypted_refresh_token,encryption_version,scopes,status
  ) values(
    v_hh,v_owner,'q110-112','cipher',1,array['https://www.googleapis.com/auth/calendar.events'],'active'
  ) returning id into v_google_conn;
  insert into public.calendar_connections(
    household_id,provider,external_calendar_id,google_connection_id,active,reauth_required
  ) values(v_hh,'google','q110-112@example.invalid',v_google_conn,true,false)
  returning id into v_cal;

  insert into public.family_events(
    household_id,title,status,all_day,starts_at,ends_at,location_text,details,
    calendar_sync_preference,created_by_actor_ref_id
  ) values(
    v_hh,'保育園面談','active',false,v_original_start,v_original_start+interval '30 minutes',
    '保育園','人が確認した予定','external_follow',v_actor_ref
  ) returning id into v_event;
  insert into public.family_event_field_authorities(household_id,family_event_id,field_name,authority_mode)
  values
    (v_hh,v_event,'title','human_protected'),
    (v_hh,v_event,'schedule','human_protected'),
    (v_hh,v_event,'location','human_protected');
  insert into public.family_event_external_links(
    household_id,family_event_id,provider,calendar_connection_id,google_event_id,
    link_mode,last_external_etag,last_reconciled_at,writer_enabled,ownership_transfer_state
  ) values(
    v_hh,v_event,'google',v_cal,'g-linked','external_follow','etag-1',now(),false,'inactive'
  );

  -- Initial provider cache matches the confirmed Family Ops truth.
  insert into public.calendar_events_cache(
    household_id,calendar_connection_id,google_event_id,title,location,starts_at,ends_at,status,etag
  ) values(
    v_hh,v_cal,'g-linked','保育園面談','保育園',v_original_start,v_original_start+interval '30 minutes','confirmed','etag-1'
  );
  if exists(select 1 from public.google_event_review_candidates where family_event_id=v_event and status='pending') then
    raise exception 'FAIL Q110: matching provider value created false diff';
  end if;

  -- Q110: Google can update its cache, but a human-protected Family Ops schedule
  -- remains untouched and receives an explicit diff candidate.
  update public.calendar_events_cache
    set starts_at=v_changed_start,ends_at=v_changed_start+interval '30 minutes',etag='etag-2'
  where calendar_connection_id=v_cal and google_event_id='g-linked';
  if (select starts_at from public.family_events where id=v_event) is distinct from v_original_start then
    raise exception 'FAIL Q110: protected Family Ops schedule was silently overwritten';
  end if;
  select * into v_candidate from public.google_event_review_candidates
    where family_event_id=v_event and candidate_kind='protected_change' and status='pending';
  if not found or not ('schedule'=any(v_candidate.changed_fields))
     or v_candidate.google_starts_at is distinct from v_changed_start then
    raise exception 'FAIL Q110: protected schedule diff candidate missing/wrong';
  end if;

  v_result:=public.server_tx_resolve_google_event_review(
    v_owner,gen_random_uuid(),v_candidate.id,v_candidate.revision,'keep_family'
  );
  if v_result->>'resolution'<>'keep_family'
     or (select starts_at from public.family_events where id=v_event) is distinct from v_original_start then
    raise exception 'FAIL Q110: keep-family review changed confirmed truth';
  end if;

  -- A later Google version raises a fresh diff; explicit acceptance may then
  -- replace the protected value, because the human chose it.
  update public.calendar_events_cache
    set starts_at=v_changed_start+interval '1 hour',ends_at=v_changed_start+interval '90 minutes',etag='etag-3'
  where calendar_connection_id=v_cal and google_event_id='g-linked';
  select * into v_candidate from public.google_event_review_candidates
    where family_event_id=v_event and candidate_kind='protected_change' and status='pending';
  perform public.server_tx_resolve_google_event_review(
    v_owner,gen_random_uuid(),v_candidate.id,v_candidate.revision,'accept_google'
  );
  if (select starts_at from public.family_events where id=v_event)
     is distinct from (v_changed_start+interval '1 hour') then
    raise exception 'FAIL Q110: explicit accept did not apply Google change';
  end if;

  -- Q111: provider deletion is only a candidate. Family Ops remains active until
  -- a human explicitly confirms the deletion.
  update public.calendar_events_cache
    set status='cancelled',tombstone_kind='deleted',etag='etag-4'
  where calendar_connection_id=v_cal and google_event_id='g-linked';
  if (select status from public.family_events where id=v_event)<>'active' then
    raise exception 'FAIL Q111: Google deletion immediately deleted/cancelled Family Ops event';
  end if;
  select * into v_candidate from public.google_event_review_candidates
    where family_event_id=v_event and candidate_kind='google_deleted' and status='pending';
  if not found then raise exception 'FAIL Q111: Google deletion candidate missing'; end if;
  perform public.server_tx_resolve_google_event_review(
    v_owner,gen_random_uuid(),v_candidate.id,v_candidate.revision,'keep_family'
  );
  if (select status from public.family_events where id=v_event)<>'active' then
    raise exception 'FAIL Q111: keep-family deletion review cancelled event';
  end if;

  -- Q112 fixture: an unlinked Google event exactly matches a separately confirmed
  -- Family Ops event. It must be a candidate, never an automatic merge/link.
  insert into public.family_events(
    household_id,title,status,all_day,starts_on,ends_on,location_text,
    calendar_sync_preference,created_by_actor_ref_id
  ) values(
    v_hh,'運動会','active',true,'2026-10-20','2026-10-20','園庭','none',v_actor_ref
  ) returning id into v_dup_event;
  insert into public.family_event_field_authorities(household_id,family_event_id,field_name,authority_mode)
  values
    (v_hh,v_dup_event,'title','human_protected'),
    (v_hh,v_dup_event,'schedule','human_protected'),
    (v_hh,v_dup_event,'location','human_protected');

  insert into public.calendar_events_cache(
    household_id,calendar_connection_id,google_event_id,title,location,
    all_day_start,all_day_end_exclusive,status,etag
  ) values(
    v_hh,v_cal,'g-dup-1','運動会','園庭','2026-10-20','2026-10-21','confirmed','dup-etag-1'
  );
  if exists(select 1 from public.family_event_external_links where calendar_connection_id=v_cal and google_event_id='g-dup-1') then
    raise exception 'FAIL Q112: duplicate candidate was auto-linked/merged';
  end if;
  select * into v_dup_candidate from public.google_event_review_candidates
    where family_event_id=v_dup_event and google_event_id='g-dup-1'
      and candidate_kind='possible_duplicate' and status='pending';
  if not found then raise exception 'FAIL Q112: duplicate candidate missing'; end if;

  -- Cross-household actor cannot resolve another family's candidate.
  v_failed:=false;
  begin
    perform public.server_tx_resolve_google_event_review(
      v_other,gen_random_uuid(),v_dup_candidate.id,v_dup_candidate.revision,'same_event'
    );
  exception when others then v_failed:=position('GOOGLE_REVIEW_NOT_FOUND' in sqlerrm)>0; end;
  if not v_failed then raise exception 'FAIL Q112: cross-household duplicate review succeeded'; end if;

  -- "別の予定" is sticky for the same provider version and creates no link.
  perform public.server_tx_resolve_google_event_review(
    v_owner,gen_random_uuid(),v_dup_candidate.id,v_dup_candidate.revision,'different_event'
  );
  perform private.fn_reconcile_google_cache_row_to_family_event_v1(v_cal,'g-dup-1');
  if exists(select 1 from public.google_event_review_candidates
      where family_event_id=v_dup_event and google_event_id='g-dup-1'
        and candidate_kind='possible_duplicate' and status='pending') then
    raise exception 'FAIL Q112: reviewed different-event decision immediately resurfaced';
  end if;
  if exists(select 1 from public.family_event_external_links where calendar_connection_id=v_cal and google_event_id='g-dup-1') then
    raise exception 'FAIL Q112: different-event review created link';
  end if;

  -- A separate duplicate candidate can explicitly be confirmed as the same event.
  insert into public.calendar_events_cache(
    household_id,calendar_connection_id,google_event_id,title,location,
    all_day_start,all_day_end_exclusive,status,etag
  ) values(
    v_hh,v_cal,'g-dup-2','運動会','園庭','2026-10-20','2026-10-21','confirmed','dup-etag-2'
  );
  select * into v_dup_candidate from public.google_event_review_candidates
    where family_event_id=v_dup_event and google_event_id='g-dup-2'
      and candidate_kind='possible_duplicate' and status='pending';
  perform public.server_tx_resolve_google_event_review(
    v_owner,gen_random_uuid(),v_dup_candidate.id,v_dup_candidate.revision,'same_event'
  );
  if not exists(select 1 from public.family_event_external_links
      where family_event_id=v_dup_event and calendar_connection_id=v_cal and google_event_id='g-dup-2') then
    raise exception 'FAIL Q112: same-event confirmation did not create explicit link';
  end if;

  if v_hh2 is null then raise exception 'FAIL fixture'; end if;
end;
$$;
reset role;
select '73_google_human_confirmed_diff_review: PASS' as result;

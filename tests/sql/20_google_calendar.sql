-- WP7: Google Calendar — OAuth state, watch channel renewal/admission, sync
-- queue state machine (coalesce/lease/reclaim), canonical sync commit
-- (tombstones/410 invalidation), occurrence projection + busy attribution
-- (transparency/all-day/creator-busy separation), manual classification,
-- deterministic-id write idempotency (409/412 style conflicts).
-- supabase/migrations/20260819000050..20260819000057_google_*.sql.
--
-- Everything here is testable without a live Google API round trip per
-- 07_GOOGLE_CALENDAR.md #15's fixture list; the actual HTTP calls
-- (token exchange, events.list/insert/patch/watch) live in the Edge
-- Functions and are exercised only by fixture jsonb payloads here.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('20000000-0000-0000-0000-000000000001'),
  ('20000000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_hh jsonb;
begin
  v_hh := public.server_tx_create_household('20000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Calendar HH', 'Owner');
  insert into public.household_members (household_id, user_id, member_role)
  values ((v_hh->>'household_id')::uuid, '20000000-0000-0000-0000-000000000002', 'adult');
end;
$$;

-- ---------------------------------------------------------------------------
-- Block 1: OAuth state — start/complete, single-use, expired/replay reject.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hh_id uuid;
  v_owner uuid := '20000000-0000-0000-0000-000000000001';
  v_partner uuid := '20000000-0000-0000-0000-000000000002';
  v_start jsonb;
  v_complete jsonb;
  v_conn_id uuid;
begin
  select id into v_hh_id from public.households where name = 'Calendar HH';

  v_start := public.server_tx_start_google_oauth(v_owner, encode(sha256('state-1'), 'hex'), '/settings/calendar');
  if v_start->>'expires_at' is null then
    raise exception 'FAIL google_calendar: oauth start did not return expires_at';
  end if;

  -- Reject a non-app-relative return_to.
  begin
    perform public.server_tx_start_google_oauth(v_owner, encode(sha256('state-bad'), 'hex'), 'https://evil.example/');
    raise exception 'FAIL google_calendar: absolute return_to must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then raise; end if;
  end;

  v_complete := public.server_tx_complete_google_oauth(
    encode(sha256('state-1'), 'hex'), 'google-subject-1', 'ciphertext-v1', 1,
    array['https://www.googleapis.com/auth/calendar.events'],
    'family-shared@group.calendar.google.com', 'Family', 'Asia/Tokyo'
  );
  if (v_complete->>'household_id')::uuid <> v_hh_id then
    raise exception 'FAIL google_calendar: oauth callback household mismatch';
  end if;
  if v_complete->>'return_to' <> '/settings/calendar' then
    raise exception 'FAIL google_calendar: oauth callback did not surface stored return_to';
  end if;
  v_conn_id := (v_complete->>'calendar_connection_id')::uuid;
  if v_conn_id is null then
    raise exception 'FAIL google_calendar: oauth callback did not create calendar_connections row';
  end if;

  -- Replay of the same (now used) state must fail.
  begin
    perform public.server_tx_complete_google_oauth(
      encode(sha256('state-1'), 'hex'), 'google-subject-1', 'ciphertext-v1', 1,
      array['https://www.googleapis.com/auth/calendar.events'], null, null, null
    );
    raise exception 'FAIL google_calendar: replayed oauth state must be rejected';
  exception
    when others then
      if sqlerrm <> 'GOOGLE_OAUTH_STATE_INVALID' then raise; end if;
  end;

  -- Unknown state hash must fail the same way.
  begin
    perform public.server_tx_complete_google_oauth(
      encode(sha256('never-issued'), 'hex'), 'x', 'y', 1, array[]::text[], null, null, null
    );
    raise exception 'FAIL google_calendar: unknown oauth state must be rejected';
  exception
    when others then
      if sqlerrm <> 'GOOGLE_OAUTH_STATE_INVALID' then raise; end if;
  end;

  -- Non-Asia/Tokyo calendar timezone is rejected (5A).
  perform public.server_tx_start_google_oauth(v_owner, encode(sha256('state-tz'), 'hex'), null);
  begin
    perform public.server_tx_complete_google_oauth(
      encode(sha256('state-tz'), 'hex'), 'google-subject-1', 'ciphertext-v1', 1,
      array['https://www.googleapis.com/auth/calendar.events'], 'other@group.calendar.google.com', 'Other', 'America/New_York'
    );
    raise exception 'FAIL google_calendar: non-Asia/Tokyo target calendar must be rejected';
  exception
    when others then
      if sqlerrm <> 'CALENDAR_TIMEZONE_UNSUPPORTED' then raise; end if;
  end;

  -- Reauth/switch-owner: partner completes OAuth again for the same
  -- household; the single connection row is reused with owner switched, not
  -- duplicated.
  perform public.server_tx_start_google_oauth(v_partner, encode(sha256('state-2'), 'hex'), null);
  perform public.server_tx_complete_google_oauth(
    encode(sha256('state-2'), 'hex'), 'google-subject-2', 'ciphertext-v2', 1,
    array['https://www.googleapis.com/auth/calendar.events'], null, null, null
  );
  if (select count(*) from private.google_connections where household_id = v_hh_id) <> 1 then
    raise exception 'FAIL google_calendar: switch-owner reauth must reuse the single connection row, not duplicate it';
  end if;
  if (select owner_user_id from private.google_connections where household_id = v_hh_id) <> v_partner then
    raise exception 'FAIL google_calendar: switch-owner reauth must update owner_user_id';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Block 2: watch channel renewal overlap + webhook admission.
-- ---------------------------------------------------------------------------
do $$
declare
  v_cc_id uuid;
begin
  select id into v_cc_id from public.calendar_connections limit 1;

  perform public.server_tx_register_google_watch_channel(v_cc_id, 'chan-a', 'res-a', 'tokhash-a', now() + interval '7 days');

  -- Valid webhook for the active channel is accepted.
  if not (public.server_tx_admit_google_webhook('chan-a', 'res-a', 'tokhash-a') ->> 'accepted')::boolean then
    raise exception 'FAIL google_calendar: valid webhook for active channel must be accepted';
  end if;

  -- Wrong resource/token for a real channel id: silently not accepted (2xx-ignore path), no exception.
  if (public.server_tx_admit_google_webhook('chan-a', 'res-a', 'wrong-token') ->> 'accepted')::boolean then
    raise exception 'FAIL google_calendar: token mismatch must not be accepted';
  end if;
  if (public.server_tx_admit_google_webhook('chan-unknown', 'res-a', 'tokhash-a') ->> 'accepted')::boolean then
    raise exception 'FAIL google_calendar: unknown channel id must not be accepted';
  end if;

  -- Renewal: new channel becomes active, old one demotes to retiring (still admits).
  perform public.server_tx_register_google_watch_channel(v_cc_id, 'chan-b', 'res-b', 'tokhash-b', now() + interval '7 days');
  if (select status from private.google_watch_channels where channel_id = 'chan-a') <> 'retiring' then
    raise exception 'FAIL google_calendar: old channel must move to retiring on renewal';
  end if;
  if not (public.server_tx_admit_google_webhook('chan-a', 'res-a', 'tokhash-a') ->> 'accepted')::boolean then
    raise exception 'FAIL google_calendar: retiring channel must still admit webhooks (overlap window)';
  end if;

  perform public.server_tx_mark_google_watch_stopped('chan-a');
  if (public.server_tx_admit_google_webhook('chan-a', 'res-a', 'tokhash-a') ->> 'accepted')::boolean then
    raise exception 'FAIL google_calendar: stopped channel must no longer admit webhooks';
  end if;

  -- chan-b expires 7 days out: with a generous 10-day lookahead it needs
  -- renewal; with a 0-minute lookahead it does not yet.
  if (select jsonb_array_length(public.server_tx_list_google_watch_channels_needing_renewal(60 * 24 * 10))) < 1 then
    raise exception 'FAIL google_calendar: a channel expiring within the renewal lookahead must be listed';
  end if;
  if (select jsonb_array_length(public.server_tx_list_google_watch_channels_needing_renewal(0))) <> 0 then
    raise exception 'FAIL google_calendar: a channel not yet within the renewal lookahead must not be listed';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Block 3: sync queue — coalesce, lease claim/reclaim, dead-letter.
-- ---------------------------------------------------------------------------
do $$
declare
  v_cc_id uuid;
  v_enq1 jsonb;
  v_enq2 jsonb;
  v_claim jsonb;
  v_claim2 jsonb;
  v_complete jsonb;
  v_job_id uuid;
begin
  select id into v_cc_id from public.calendar_connections limit 1;

  v_enq1 := public.server_tx_enqueue_google_sync(v_cc_id, 'webhook');
  if v_enq1->>'coalesced' <> 'false' then
    raise exception 'FAIL google_calendar: first enqueue on an empty queue must not be coalesced';
  end if;

  -- Second enqueue while still queued coalesces into the same job.
  v_enq2 := public.server_tx_enqueue_google_sync(v_cc_id, 'manual');
  if v_enq2->>'coalesced' <> 'true' or v_enq2->>'job_id' <> v_enq1->>'job_id' then
    raise exception 'FAIL google_calendar: second enqueue while queued must coalesce into the same job';
  end if;
  if (select count(*) from private.google_sync_jobs where calendar_connection_id = v_cc_id) <> 1 then
    raise exception 'FAIL google_calendar: coalescing must never create a second row';
  end if;

  -- Claim it (worker A).
  v_claim := public.server_tx_claim_google_sync_job('worker-a', 120);
  if v_claim is null then
    raise exception 'FAIL google_calendar: claim should have returned the queued job';
  end if;
  v_job_id := (v_claim->>'job_id')::uuid;
  if (select status from private.google_sync_jobs where id = v_job_id) <> 'processing' then
    raise exception 'FAIL google_calendar: claimed job must be processing';
  end if;

  -- A second concurrent claim attempt finds nothing else queued.
  v_claim2 := public.server_tx_claim_google_sync_job('worker-b', 120);
  if v_claim2 is not null then
    raise exception 'FAIL google_calendar: no second job should be claimable while the only job is leased';
  end if;

  -- Enqueue while processing sets rerun_requested rather than a new row.
  perform public.server_tx_enqueue_google_sync(v_cc_id, 'webhook-again');
  if (select rerun_requested from private.google_sync_jobs where id = v_job_id) is not true then
    raise exception 'FAIL google_calendar: enqueue while processing must set rerun_requested';
  end if;
  if (select count(*) from private.google_sync_jobs where calendar_connection_id = v_cc_id) <> 1 then
    raise exception 'FAIL google_calendar: enqueue while processing must not create a second row';
  end if;

  -- A stale/wrong lease token cannot complete the job (protects against a
  -- worker that was already reclaimed from clobbering the new owner).
  begin
    perform public.server_tx_complete_google_sync_job(v_job_id, gen_random_uuid(), true, null);
    raise exception 'FAIL google_calendar: completing with the wrong lease token must fail';
  exception
    when others then
      if sqlerrm <> 'GOOGLE_SYNC_LEASE_LOST' then raise; end if;
  end;

  -- Success + rerun_requested requeues immediately instead of going 'done'.
  v_complete := public.server_tx_complete_google_sync_job(v_job_id, (v_claim->>'lease_token')::uuid, true, null);
  if v_complete->>'status' <> 'queued' then
    raise exception 'FAIL google_calendar: success with rerun_requested must requeue, got %', v_complete->>'status';
  end if;
  if (select rerun_requested from private.google_sync_jobs where id = v_job_id) is not false then
    raise exception 'FAIL google_calendar: rerun_requested must be cleared after requeue';
  end if;

  -- Claim again, this time succeed cleanly -> done.
  v_claim := public.server_tx_claim_google_sync_job('worker-a', 120);
  v_complete := public.server_tx_complete_google_sync_job(v_job_id, (v_claim->>'lease_token')::uuid, true, null);
  if v_complete->>'status' <> 'done' then
    raise exception 'FAIL google_calendar: clean success must mark the job done';
  end if;

  -- Reclaim path: enqueue a fresh job, claim it, then simulate a crashed
  -- worker by forcing its lease into the past; a second claim should
  -- reclaim it rather than staying stuck forever.
  perform public.server_tx_enqueue_google_sync(v_cc_id, 'periodic');
  v_claim := public.server_tx_claim_google_sync_job('worker-crash', 120);
  v_job_id := (v_claim->>'job_id')::uuid;
  update private.google_sync_jobs set lease_until = now() - interval '1 second' where id = v_job_id;

  v_claim2 := public.server_tx_claim_google_sync_job('worker-rescue', 120);
  if v_claim2 is null or (v_claim2->>'job_id')::uuid <> v_job_id then
    raise exception 'FAIL google_calendar: an expired lease must be reclaimable by another worker';
  end if;
  if (select attempts from private.google_sync_jobs where id = v_job_id) <> 2 then
    raise exception 'FAIL google_calendar: reclaim must bump attempts';
  end if;

  -- The original (crashed) worker's lease token is now stale and must be rejected.
  begin
    perform public.server_tx_complete_google_sync_job(v_job_id, (v_claim->>'lease_token')::uuid, true, null);
    raise exception 'FAIL google_calendar: the crashed worker''s stale lease token must be rejected after reclaim';
  exception
    when others then
      if sqlerrm <> 'GOOGLE_SYNC_LEASE_LOST' then raise; end if;
  end;

  -- Repeated failure eventually dead-letters. Force next_attempt_at back to
  -- now() between retries so the assertion exercises the attempt-ceiling
  -- logic itself rather than waiting out the real exponential backoff delay.
  v_complete := public.server_tx_complete_google_sync_job(v_job_id, (v_claim2->>'lease_token')::uuid, false, 'boom');
  if v_complete->>'status' <> 'queued' then
    raise exception 'FAIL google_calendar: a failure below the attempt ceiling must requeue';
  end if;
  for i in 1..4 loop
    update private.google_sync_jobs set next_attempt_at = now() where id = v_job_id and status = 'queued';
    v_claim := public.server_tx_claim_google_sync_job('retry-worker', 120);
    exit when v_claim is null;
    perform public.server_tx_complete_google_sync_job((v_claim->>'job_id')::uuid, (v_claim->>'lease_token')::uuid, false, 'boom-again');
  end loop;
  if (select status from private.google_sync_jobs where id = v_job_id) <> 'dead' then
    raise exception 'FAIL google_calendar: exhausting attempts must dead-letter the job, got %',
      (select status from private.google_sync_jobs where id = v_job_id);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Block 4: canonical sync — staging, atomic commit, tombstones, 410.
-- ---------------------------------------------------------------------------
do $$
declare
  v_cc_id uuid;
  v_run1 uuid := gen_random_uuid();
  v_run2 uuid := gen_random_uuid();
  v_commit jsonb;
begin
  select id into v_cc_id from public.calendar_connections limit 1;

  -- Initial full sync page: a normal event, an untitled event, an id-only
  -- deleted event, and a minimal cancelled recurring exception.
  perform public.server_tx_stage_google_events(v_cc_id, v_run1, jsonb_build_array(
    jsonb_build_object(
      'id', 'evt-normal', 'summary', 'Piano', 'status', 'confirmed',
      'start', jsonb_build_object('dateTime', '2026-08-20T10:00:00+09:00'),
      'end', jsonb_build_object('dateTime', '2026-08-20T11:00:00+09:00'),
      'updated', '2026-08-19T00:00:00Z', 'etag', '"e1"'
    ),
    jsonb_build_object(
      'id', 'evt-untitled', 'status', 'confirmed',
      'start', jsonb_build_object('dateTime', '2026-08-21T10:00:00+09:00'),
      'end', jsonb_build_object('dateTime', '2026-08-21T11:00:00+09:00')
    ),
    jsonb_build_object('id', 'evt-deleted', 'status', 'cancelled'),
    jsonb_build_object('id', 'evt-cancelled-exc', 'status', 'cancelled', 'recurringEventId', 'evt-series', 'originalStartTime', jsonb_build_object('dateTime', '2026-08-22T10:00:00+09:00'))
  ));

  v_commit := public.server_tx_commit_google_sync(v_cc_id, v_run1, 'sync-token-1', true);
  if (v_commit->>'upserted_count')::int <> 4 then
    raise exception 'FAIL google_calendar: expected 4 upserted rows on initial full sync, got %', v_commit->>'upserted_count';
  end if;
  if (select next_sync_token from private.google_sync_state where calendar_connection_id = v_cc_id) <> 'sync-token-1' then
    raise exception 'FAIL google_calendar: syncToken must be stored only after final-page commit';
  end if;
  if exists (select 1 from private.google_event_staging where sync_run_id = v_run1) then
    raise exception 'FAIL google_calendar: staging rows for a committed run must be cleaned up';
  end if;

  if (select title from public.calendar_events_cache where google_event_id = 'evt-untitled') is not null then
    raise exception 'FAIL google_calendar: untitled event must store title=null, not a placeholder string';
  end if;
  if (select tombstone_kind from public.calendar_events_cache where google_event_id = 'evt-deleted') <> 'deleted' then
    raise exception 'FAIL google_calendar: id-only deleted event must be tombstone_kind=deleted';
  end if;
  if (select starts_at from public.calendar_events_cache where google_event_id = 'evt-deleted') is not null then
    raise exception 'FAIL google_calendar: an id-only deleted event must never require start/end';
  end if;
  if (select tombstone_kind from public.calendar_events_cache where google_event_id = 'evt-cancelled-exc') <> 'cancelled_exception' then
    raise exception 'FAIL google_calendar: cancelled recurring exception must be tombstone_kind=cancelled_exception';
  end if;

  -- Incremental sync: evt-normal renamed, nothing else touched. Nullable
  -- fields must not block the token from advancing.
  perform public.server_tx_stage_google_events(v_cc_id, v_run2, jsonb_build_array(
    jsonb_build_object(
      'id', 'evt-normal', 'summary', 'Piano (moved)', 'status', 'confirmed',
      'start', jsonb_build_object('dateTime', '2026-08-20T11:00:00+09:00'),
      'end', jsonb_build_object('dateTime', '2026-08-20T12:00:00+09:00')
    )
  ));
  perform public.server_tx_commit_google_sync(v_cc_id, v_run2, 'sync-token-2', false);
  if (select next_sync_token from private.google_sync_state where calendar_connection_id = v_cc_id) <> 'sync-token-2' then
    raise exception 'FAIL google_calendar: incremental sync must advance the syncToken despite nullable fields elsewhere';
  end if;
  -- Incremental sync must not implicitly tombstone rows it simply didn't mention.
  if (select tombstone_kind from public.calendar_events_cache where google_event_id = 'evt-untitled') is not null then
    raise exception 'FAIL google_calendar: incremental sync must not implicitly delete events it did not restate';
  end if;

  -- 410 Gone: clears the token so the next run must perform a fresh full sync.
  perform public.server_tx_invalidate_google_sync_token(v_cc_id, '410 Gone');
  if (select next_sync_token from private.google_sync_state where calendar_connection_id = v_cc_id) is not null then
    raise exception 'FAIL google_calendar: 410 handling must null out the stored syncToken';
  end if;

  -- Full resync that omits evt-untitled implies it was deleted while the
  -- token was invalid (fell out of Google's own tombstone retention).
  perform public.server_tx_stage_google_events(v_cc_id, gen_random_uuid(), jsonb_build_array(
    jsonb_build_object(
      'id', 'evt-normal', 'summary', 'Piano (moved)', 'status', 'confirmed',
      'start', jsonb_build_object('dateTime', '2026-08-20T11:00:00+09:00'),
      'end', jsonb_build_object('dateTime', '2026-08-20T12:00:00+09:00')
    )
  ));
end;
$$;

-- ---------------------------------------------------------------------------
-- Block 5: occurrence projection + busy attribution.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hh_id uuid;
  v_cc_id uuid;
  v_owner uuid := '20000000-0000-0000-0000-000000000001';
  v_partner uuid := '20000000-0000-0000-0000-000000000002';
  v_result jsonb;
begin
  select id into v_hh_id from public.households where name = 'Calendar HH';
  select id into v_cc_id from public.calendar_connections limit 1;

  v_result := public.server_tx_rebuild_google_occurrence_projection(
    v_cc_id, '2026-08-13'::date, '2026-10-18'::date,
    jsonb_build_array(
      -- family-ops-created event with explicit busy metadata -> both busy.
      jsonb_build_object(
        'id', 'evt-family', 'summary', 'Family outing', 'status', 'confirmed',
        'start', jsonb_build_object('dateTime', '2026-08-20T10:00:00+09:00'),
        'end', jsonb_build_object('dateTime', '2026-08-20T12:00:00+09:00'),
        'extendedProperties', jsonb_build_object('private', jsonb_build_object(
          'familyOpsBusyMemberIds', v_owner::text || ',' || v_partner::text
        ))
      ),
      -- papa creates mama's event -> mama busy only.
      jsonb_build_object(
        'id', 'evt-mama-only', 'summary', 'Mama dentist', 'status', 'confirmed',
        'start', jsonb_build_object('dateTime', '2026-08-21T09:00:00+09:00'),
        'end', jsonb_build_object('dateTime', '2026-08-21T10:00:00+09:00'),
        'extendedProperties', jsonb_build_object('private', jsonb_build_object(
          'familyOpsBusyMemberIds', v_partner::text
        ))
      ),
      -- direct Google-created event, no metadata -> unknown busy owner.
      jsonb_build_object(
        'id', 'evt-direct-unknown', 'summary', 'Dentist (direct)', 'status', 'confirmed',
        'start', jsonb_build_object('dateTime', '2026-08-22T09:00:00+09:00'),
        'end', jsonb_build_object('dateTime', '2026-08-22T10:00:00+09:00')
      ),
      -- transparent event: projected, but flagged transparent for conflict logic to skip.
      jsonb_build_object(
        'id', 'evt-transparent', 'summary', 'FYI block', 'status', 'confirmed', 'transparency', 'transparent',
        'start', jsonb_build_object('dateTime', '2026-08-23T09:00:00+09:00'),
        'end', jsonb_build_object('dateTime', '2026-08-23T10:00:00+09:00'),
        'extendedProperties', jsonb_build_object('private', jsonb_build_object('familyOpsBusyMemberIds', v_owner::text))
      ),
      -- all-day event: projected with all_day_start/end, no starts_at/ends_at.
      jsonb_build_object(
        'id', 'evt-allday', 'summary', 'Sports day', 'status', 'confirmed',
        'start', jsonb_build_object('date', '2026-08-24'),
        'end', jsonb_build_object('date', '2026-08-25'),
        'extendedProperties', jsonb_build_object('private', jsonb_build_object('familyOpsBusyMemberIds', v_owner::text))
      ),
      -- cancelled instance must never enter the active projection.
      jsonb_build_object('id', 'evt-cancelled-instance', 'status', 'cancelled')
    )
  );

  if (v_result->>'upserted_occurrences')::int <> 5 then
    raise exception 'FAIL google_calendar: expected 5 active occurrences (cancelled instance excluded), got %', v_result->>'upserted_occurrences';
  end if;
  if exists (select 1 from public.calendar_event_occurrences where google_event_id = 'evt-cancelled-instance') then
    raise exception 'FAIL google_calendar: a cancelled instance must never enter the active projection';
  end if;

  -- family event => both busy.
  if (select count(*) from public.calendar_occurrence_busy_members where occurrence_key = 'event:evt-family') <> 2 then
    raise exception 'FAIL google_calendar: family-scope event must have both members busy';
  end if;

  -- papa creates mama's event => mama busy only.
  if (select array_agg(user_id) from public.calendar_occurrence_busy_members where occurrence_key = 'event:evt-mama-only') <> array[v_partner] then
    raise exception 'FAIL google_calendar: busy attribution must reflect the chosen busy member, not the creator';
  end if;

  -- unknown direct event => no busy members at all (no false-positive person warning).
  if exists (select 1 from public.calendar_occurrence_busy_members where occurrence_key = 'event:evt-direct-unknown') then
    raise exception 'FAIL google_calendar: a direct event with no Family Ops metadata must have unknown/no busy members';
  end if;

  -- transparency stored for the conflict-detection consumer to filter on.
  if (select transparency from public.calendar_event_occurrences where occurrence_key = 'event:evt-transparent') <> 'transparent' then
    raise exception 'FAIL google_calendar: transparency must be stored on the occurrence row';
  end if;

  -- all-day flagged via all_day_start/end with null starts_at/ends_at.
  if (select (starts_at is not null) or (all_day_start is null) from public.calendar_event_occurrences where occurrence_key = 'event:evt-allday') then
    raise exception 'FAIL google_calendar: all-day occurrence must have all_day_start set and starts_at null';
  end if;

  -- Re-run the rebuild omitting evt-transparent (event moved out of window /
  -- no longer returned): it must be pruned from the projection.
  v_result := public.server_tx_rebuild_google_occurrence_projection(
    v_cc_id, '2026-08-13'::date, '2026-10-18'::date,
    jsonb_build_array(
      jsonb_build_object(
        'id', 'evt-family', 'summary', 'Family outing', 'status', 'confirmed',
        'start', jsonb_build_object('dateTime', '2026-08-20T10:00:00+09:00'),
        'end', jsonb_build_object('dateTime', '2026-08-20T12:00:00+09:00')
      )
    )
  );
  if exists (select 1 from public.calendar_event_occurrences where occurrence_key = 'event:evt-transparent') then
    raise exception 'FAIL google_calendar: an occurrence dropped from a window rebuild must be pruned';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Block 6: manual busy classification precedence + immediate effect.
-- ---------------------------------------------------------------------------
do $$
declare
  v_cc_id uuid;
  v_owner uuid := '20000000-0000-0000-0000-000000000001';
  v_partner uuid := '20000000-0000-0000-0000-000000000002';
  v_op1 uuid := gen_random_uuid();
  v_op2 uuid := gen_random_uuid();
begin
  select id into v_cc_id from public.calendar_connections limit 1;

  -- Manual override on the previously-"unknown" direct event: self only.
  perform public.server_tx_classify_calendar_busy(
    v_owner, v_op1, v_cc_id, 'evt-direct-unknown', null, 'self', array[v_owner]
  );
  if (select array_agg(user_id) from public.calendar_occurrence_busy_members where occurrence_key = 'event:evt-direct-unknown') <> array[v_owner] then
    raise exception 'FAIL google_calendar: manual classification must take immediate effect on the existing occurrence row';
  end if;

  -- Same operation_id retried with the identical payload is a no-op success (idempotent).
  perform public.server_tx_classify_calendar_busy(
    v_owner, v_op1, v_cc_id, 'evt-direct-unknown', null, 'self', array[v_owner]
  );

  -- Same operation_id, different payload -> IDEMPOTENCY_CONFLICT.
  begin
    perform public.server_tx_classify_calendar_busy(
      v_owner, v_op1, v_cc_id, 'evt-direct-unknown', null, 'family', array[v_owner, v_partner]
    );
    raise exception 'FAIL google_calendar: same operation_id with a different payload must be IDEMPOTENCY_CONFLICT';
  exception
    when others then
      if sqlerrm <> 'IDEMPOTENCY_CONFLICT' then raise; end if;
  end;

  -- unknown scope must carry no members.
  perform public.server_tx_classify_calendar_busy(v_owner, v_op2, v_cc_id, 'evt-mama-only', null, 'unknown', null);
  if exists (select 1 from public.calendar_occurrence_busy_members where occurrence_key = 'event:evt-mama-only') then
    raise exception 'FAIL google_calendar: unknown scope must clear busy members';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Block 7: deterministic-id writes — create/update idempotency ledger.
-- ---------------------------------------------------------------------------
do $$
declare
  v_cc_id uuid;
  v_owner uuid := '20000000-0000-0000-0000-000000000001';
  v_op uuid := gen_random_uuid();
  v_claim jsonb;
  v_claim_retry jsonb;
  v_expected_id text;
  v_final jsonb;
begin
  select id into v_cc_id from public.calendar_connections limit 1;
  v_expected_id := 'fo' || replace(lower(v_op::text), '-', '');

  v_claim := public.server_tx_claim_google_write(v_owner, v_op, v_cc_id, 'create', 'hash-1', null);
  if v_claim->>'google_event_id' <> v_expected_id then
    raise exception 'FAIL google_calendar: deterministic google_event_id mismatch, expected % got %', v_expected_id, v_claim->>'google_event_id';
  end if;
  if v_claim->>'status' <> 'pending' then
    raise exception 'FAIL google_calendar: freshly claimed write must be pending';
  end if;

  -- Response-lost retry: same operation_id + same payload hash claims the
  -- same google_event_id again (caller retries the provider insert with it).
  v_claim_retry := public.server_tx_claim_google_write(v_owner, v_op, v_cc_id, 'create', 'hash-1', null);
  if v_claim_retry->>'google_event_id' <> v_expected_id then
    raise exception 'FAIL google_calendar: retried claim must return the same deterministic id';
  end if;

  -- Same operation_id + different local payload is blocked (#11).
  begin
    perform public.server_tx_claim_google_write(v_owner, v_op, v_cc_id, 'create', 'hash-DIFFERENT', null);
    raise exception 'FAIL google_calendar: same operation_id with a different payload hash must be blocked';
  exception
    when others then
      if sqlerrm <> 'IDEMPOTENCY_CONFLICT' then raise; end if;
  end;

  -- Finalize as succeeded with an etag; a same-status retry is a no-op.
  v_final := public.server_tx_finalize_google_write(v_op, 'succeeded', '"etag-1"', null);
  if v_final->>'status' <> 'succeeded' then
    raise exception 'FAIL google_calendar: finalize must record succeeded status';
  end if;
  if (select result_etag from private.google_write_operations where operation_id = v_op) <> '"etag-1"' then
    raise exception 'FAIL google_calendar: finalize must persist the result etag';
  end if;

  -- A brand new operation_id always gets its own distinct deterministic id.
  declare
    v_op2 uuid := gen_random_uuid();
    v_claim2 jsonb;
  begin
    v_claim2 := public.server_tx_claim_google_write(v_owner, v_op2, v_cc_id, 'update', 'hash-2', 'existing-event-id-123');
    if v_claim2->>'google_event_id' = v_expected_id then
      raise exception 'FAIL google_calendar: distinct operations must never collide on the deterministic id';
    end if;
  end;
end;
$$;

reset role;

select 'google_calendar: PASS' as result;

-- WP-DD4: legacy public adapters route through canonical Attempts, and an
-- accepted Request remains accepted while post-accept Task changes/cancel are
-- negotiated and applied only after the other party confirms the same terms.

do $$
declare
  v_owner uuid := '10000000-0000-0000-0000-000000000044';
  v_partner uuid := '10000000-0000-0000-0000-000000000144';
  v_household uuid;
  v_owner_ref uuid;
  v_request uuid;
  v_task uuid;
  v_request_revision bigint;
  v_task_revision bigint;
  v_change jsonb;
  v_cancel jsonb;
  v_accepted_at timestamptz;
begin
  insert into auth.users (id) values
    (v_owner),
    (v_partner)
  on conflict (id) do nothing;
  insert into public.profiles (user_id,display_name) values
    (v_owner,'DD4 owner'),(v_partner,'DD4 partner')
  on conflict (user_id) do nothing;

  v_household := (public.server_tx_create_household(
    v_owner, '20000000-0000-0000-0000-000000000044',
    'DD4 household', 'Asia/Tokyo'
  )->>'household_id')::uuid;
  insert into public.household_members (household_id,user_id,member_role,family_role)
  values (v_household,v_partner,'adult','mama');

  select id into v_owner_ref from public.domain_actor_refs
  where household_id=v_household and actor_kind='real_user' and real_user_id=v_owner;
  if v_owner_ref is null or not exists (
    select 1 from public.domain_actor_refs
    where household_id=v_household and actor_kind='real_user' and real_user_id=v_partner
  ) then raise exception 'FAIL DD4: member ActorRef continuity unavailable'; end if;

  v_request := (public.server_tx_send_request(
    v_owner, '20000000-0000-0000-0000-000000000144', v_partner,
    '園バッグを用意', '明日の朝までにお願いします',
    '2026-09-05 08:00+09'::timestamptz
  )->>'request_id')::uuid;

  -- Exact replay returns the same aggregate and must not duplicate LINE actions.
  if (public.server_tx_send_request(
    v_owner, '20000000-0000-0000-0000-000000000144', v_partner,
    '園バッグを用意', '明日の朝までにお願いします',
    '2026-09-05 08:00+09'::timestamptz
  )->>'request_id')::uuid <> v_request then
    raise exception 'FAIL DD4: request create replay changed identity';
  end if;
  if (select count(*) from private.pending_actions
      where actor_id=v_partner and normalized_payload->>'request_id'=v_request::text
        and action_type in ('request_accept','request_decline')) <> 2 then
    raise exception 'FAIL DD4: canonical request response actions duplicated';
  end if;

  v_task := (public.server_tx_accept_request(
    v_partner, '20000000-0000-0000-0000-000000000244', v_request
  )->>'task_id')::uuid;
  select revision into v_request_revision from public.requests where id=v_request;
  select revision into v_task_revision from public.task_instances where id=v_task;
  select accepted_at into v_accepted_at from public.requests where id=v_request;

  v_change := public.server_tx_start_request_followup(
    v_owner, '20000000-0000-0000-0000-000000000344', v_request,
    'change', jsonb_build_object(
      'scheduled_date','2026-09-06',
      'due_at','2026-09-06T09:00:00+09:00'
    ), '日程変更', '2026-09-05 20:00+09'::timestamptz,
    v_request_revision, v_task_revision
  );

  if not exists (
    select 1 from public.requests
    where id=v_request and status='accepted' and accepted_at=v_accepted_at
  ) then raise exception 'FAIL DD4: pending followup overwrote accepted agreement'; end if;
  if exists (
    select 1 from public.task_instances
    where id=v_task and scheduled_date='2026-09-06'::date
  ) then raise exception 'FAIL DD4: proposed change applied before confirmation'; end if;

  perform public.server_tx_accept_request(
    v_partner, '20000000-0000-0000-0000-000000000444', v_request
  );
  if not exists (
    select 1 from public.task_instances
    where id=v_task and scheduled_date='2026-09-06'::date
      and due_at='2026-09-06 09:00+09'::timestamptz
  ) then raise exception 'FAIL DD4: accepted change did not atomically update Task'; end if;
  if not exists (
    select 1 from public.request_attempts
    where id=(v_change->>'attempt_id')::uuid and attempt_kind='change' and state='accepted'
  ) then raise exception 'FAIL DD4: change Attempt history missing'; end if;

  select revision into v_request_revision from public.requests where id=v_request;
  select revision into v_task_revision from public.task_instances where id=v_task;
  v_cancel := public.server_tx_start_request_followup(
    v_owner, '20000000-0000-0000-0000-000000000544', v_request,
    'cancel', null, '予定がなくなった', '2026-09-05 21:00+09'::timestamptz,
    v_request_revision, v_task_revision
  );
  if (select status from public.task_instances where id=v_task) <> 'todo' then
    raise exception 'FAIL DD4: cancel proposal changed execution before confirmation';
  end if;
  perform public.server_tx_accept_request(
    v_partner, '20000000-0000-0000-0000-000000000644', v_request
  );
  if (select status from public.task_instances where id=v_task) <> 'cancelled' then
    raise exception 'FAIL DD4: accepted cancel did not cancel linked Task';
  end if;
  if not exists (
    select 1 from public.requests
    where id=v_request and status='accepted' and accepted_at=v_accepted_at
      and completed_at is null and cancelled_at is null
  ) then raise exception 'FAIL DD4: post-accept cancel corrupted legacy agreement tuple'; end if;
  if not exists (
    select 1 from public.request_attempts
    where id=(v_cancel->>'attempt_id')::uuid and attempt_kind='cancel' and state='accepted'
  ) then raise exception 'FAIL DD4: cancel Attempt history missing'; end if;
end;
$$;

select 'PASS WP-DD4 canonical Request cutover' as result;

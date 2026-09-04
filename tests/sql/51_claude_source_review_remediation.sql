-- PR #45 independent Claude source-review remediation regressions.
-- Covers completed Request preservation across a later follow-up decline,
-- CURRENT handover-read -> canonical acknowledgement compatibility, and R0
-- authenticated reader gating/fallback without advancing any capability.
\set ON_ERROR_STOP on

set role service_role;
do $$
declare
  v_owner constant uuid := '51000000-0000-0000-0000-000000000001';
  v_partner constant uuid := '51000000-0000-0000-0000-000000000002';
  v_hh jsonb;
  v_household uuid;
  v_owner_ref uuid;
  v_partner_ref uuid;
  v_request uuid;
  v_task uuid;
  v_followup jsonb;
  v_attempt uuid;
  v_request_revision bigint;
  v_task_revision bigint;
  v_completed_at timestamptz;
  v_handover uuid;
  v_brief jsonb;
  v_bad_gates bigint;
begin
  insert into auth.users(id) values (v_owner), (v_partner)
  on conflict (id) do nothing;
  insert into public.profiles(user_id, display_name) values
    (v_owner, 'Claude remediation owner'),
    (v_partner, 'Claude remediation partner')
  on conflict (user_id) do nothing;

  v_hh := public.server_tx_create_household(
    v_owner,
    '51000000-0000-0000-0000-000000000010',
    'Claude source-review remediation',
    'Asia/Tokyo'
  );
  v_household := (v_hh->>'household_id')::uuid;
  insert into public.household_members(household_id, user_id, member_role, family_role)
  values (v_household, v_partner, 'adult', 'mama');

  select id into v_owner_ref
  from public.domain_actor_refs
  where household_id = v_household and actor_kind = 'real_user' and real_user_id = v_owner;
  select id into v_partner_ref
  from public.domain_actor_refs
  where household_id = v_household and actor_kind = 'real_user' and real_user_id = v_partner;
  if v_owner_ref is null or v_partner_ref is null then
    raise exception 'FAIL Claude remediation: real ActorRef continuity missing';
  end if;

  -- -----------------------------------------------------------------------
  -- HIGH-2: response-lost / delayed follow-up decline after Task completion
  -- must never erase Request completion history.
  -- -----------------------------------------------------------------------
  v_request := (public.server_tx_send_request(
    v_owner,
    '51000000-0000-0000-0000-000000000101',
    v_partner,
    '完了履歴を守るお願い',
    '完了後の変更提案 decline でも巻き戻さない',
    now() + interval '1 day'
  )->>'request_id')::uuid;

  v_task := (public.server_tx_accept_request(
    v_partner,
    '51000000-0000-0000-0000-000000000102',
    v_request
  )->>'task_id')::uuid;

  select revision into v_request_revision from public.requests where id = v_request;
  select revision into v_task_revision from public.task_instances where id = v_task;

  v_followup := public.server_tx_start_request_followup(
    v_owner,
    '51000000-0000-0000-0000-000000000103',
    v_request,
    'change',
    jsonb_build_object('scheduled_date', (current_date + 1)::text),
    '完了前に提案した変更',
    now() + interval '2 hours',
    v_request_revision,
    v_task_revision
  );
  v_attempt := (v_followup->>'attempt_id')::uuid;

  perform private.fn_command_complete_task_v1(
    v_household,
    v_partner,
    v_partner_ref,
    null,
    v_task,
    array[v_partner_ref],
    v_task_revision,
    '51000000-0000-0000-0000-000000000104',
    'pwa'
  );

  select completed_at into v_completed_at
  from public.requests
  where id = v_request and status = 'completed';
  if v_completed_at is null then
    raise exception 'FAIL Claude remediation: canonical Task completion did not complete linked Request';
  end if;

  perform private.fn_command_decline_request_followup_v1(
    v_household,
    v_partner,
    v_partner_ref,
    null,
    v_request,
    v_attempt,
    1,
    '51000000-0000-0000-0000-000000000105',
    'pwa'
  );

  if not exists (
    select 1 from public.requests
    where id = v_request
      and status = 'completed'
      and completed_at = v_completed_at
      and declined_at is null
      and cancelled_at is null
  ) then
    raise exception 'FAIL Claude remediation: follow-up decline rolled Request completion backward';
  end if;
  if not exists (
    select 1 from public.task_instances
    where id = v_task and status = 'completed' and completed_at is not null
  ) then
    raise exception 'FAIL Claude remediation: linked Task completion truth changed';
  end if;
  if not exists (
    select 1 from public.request_attempts
    where id = v_attempt and attempt_kind = 'change' and state = 'declined'
  ) then
    raise exception 'FAIL Claude remediation: declined follow-up history missing';
  end if;

  -- -----------------------------------------------------------------------
  -- HIGH-3: the existing mark-handover-read path must write the canonical
  -- ActorRef acknowledgement in the same DB transaction, so DailyBrief and
  -- CURRENT Today semantics cannot disagree.
  -- -----------------------------------------------------------------------
  v_handover := (public.server_tx_create_handover(
    v_partner,
    '51000000-0000-0000-0000-000000000106',
    '既読互換性の確認',
    'day',
    array['general']::text[],
    current_date
  )->>'handover_id')::uuid;

  perform public.server_tx_mark_handover_read(
    v_owner,
    '51000000-0000-0000-0000-000000000107',
    v_handover
  );

  if not exists (
    select 1 from public.handover_reads
    where household_id = v_household and handover_id = v_handover and user_id = v_owner
  ) then
    raise exception 'FAIL Claude remediation: legacy handover read missing';
  end if;
  if not exists (
    select 1 from public.info_acknowledgements
    where household_id = v_household and handover_id = v_handover
      and actor_ref_id = v_owner_ref and test_context_id is null
  ) then
    raise exception 'FAIL Claude remediation: canonical info acknowledgement missing';
  end if;

  v_brief := public.server_read_daily_brief(v_owner, current_date);
  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_brief->'handovers', '[]'::jsonb)) h
    where h->>'handover_id' = v_handover::text
  ) then
    raise exception 'FAIL Claude remediation: acknowledged handover still appears unread in canonical brief';
  end if;

  -- -----------------------------------------------------------------------
  -- HIGH-4 / DD11: this remediation itself must not advance a capability.
  -- -----------------------------------------------------------------------
  select count(*) into v_bad_gates
  from private.canonical_capability_gates
  where release_stage <> 'R0'
     or reader_enabled
     or writer_enabled
     or not mutation_paused
     or p1_crossed_at is not null;
  if v_bad_gates <> 0 then
    raise exception 'FAIL Claude remediation: capability gate advanced during source remediation count=%', v_bad_gates;
  end if;
end;
$$;
reset role;

-- Authenticated product entrypoints must not reach canonical R0 readers.
-- Shopping is the deliberate compatibility exception: the wrapper returns a
-- legacy-shaped R0 workspace without invoking the canonical workspace reader.
set role authenticated;
set request.jwt.claim.sub = '51000000-0000-0000-0000-000000000001';
set request.jwt.claim.role = 'authenticated';

do $$
declare
  v_workspace jsonb;
begin
  begin
    perform public.get_my_daily_brief(current_date);
    raise exception 'FAIL Claude remediation: DailyBrief canonical reader reachable in R0';
  exception when others then
    if sqlerrm not like '%CAPABILITY_READER_NOT_ENABLED:daily_brief_v2%' then raise; end if;
  end;

  begin
    perform public.get_my_request_workspace();
    raise exception 'FAIL Claude remediation: Request canonical reader reachable in R0';
  exception when others then
    if sqlerrm not like '%CAPABILITY_READER_NOT_ENABLED:request_negotiation_v2%' then raise; end if;
  end;

  begin
    perform public.get_my_task_result_history(current_date - 14);
    raise exception 'FAIL Claude remediation: Task history canonical reader reachable in R0';
  exception when others then
    if sqlerrm not like '%CAPABILITY_READER_NOT_ENABLED:actual_reconciliation_v2%' then raise; end if;
  end;

  v_workspace := public.get_my_shopping_workspace();
  if v_workspace->>'reader_mode' <> 'legacy_r0' then
    raise exception 'FAIL Claude remediation: Shopping did not use legacy R0 fallback: %', v_workspace;
  end if;
end;
$$;

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

select '51_claude_source_review_remediation: PASS' as result;

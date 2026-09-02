-- WP-DD1/DD2 remainder + WP-DD3A/DD3 command prerequisites.
--
-- This migration stays R0/R1: it evolves compatibility schema and adds private
-- server-only helpers, but does not activate a canonical reader/writer, enqueue
-- test state into production LINE, write Google, or cross P1.

-- ---------------------------------------------------------------------------
-- ActorRef-capable legacy compatibility columns required by one-user test mode
-- ---------------------------------------------------------------------------

-- CURRENT already has assignment_task_instance_id from the 20260821 assignment
-- change migration. Do not duplicate it here. Relax only the real-user mirrors
-- that block a simulated ActorRef from being represented honestly.
alter table public.requests
  alter column requester_id drop not null,
  alter column recipient_id drop not null,
  add constraint requests_requester_identity_present_v2
    check (requester_id is not null or requester_actor_ref_id is not null),
  add constraint requests_recipient_identity_present_v2
    check (recipient_id is not null or recipient_actor_ref_id is not null),
  add constraint requests_canonical_parties_distinct_v2
    check (
      requester_actor_ref_id is null
      or recipient_actor_ref_id is null
      or requester_actor_ref_id <> recipient_actor_ref_id
    );

alter table public.task_events
  alter column actor_id drop not null,
  add constraint task_events_actor_identity_present_v2
    check (actor_id is not null or actor_ref_id is not null);

alter table public.handovers
  alter column author_id drop not null,
  add column info_kind text not null default 'handover'
    check (info_kind in ('share', 'handover')),
  add column visibility text not null default 'household'
    check (visibility in ('household', 'self')),
  add column valid_from timestamptz null,
  add column valid_until timestamptz null,
  add column ack_policy text not null default 'none'
    check (ack_policy in ('none', 'required')),
  add column related_task_id uuid null,
  add column status text not null default 'active'
    check (status in ('active', 'superseded', 'expired')),
  add column supersedes_handover_id uuid null,
  add column revision bigint not null default 1 check (revision >= 1),
  add foreign key (household_id, related_task_id)
    references public.task_instances (household_id, id),
  add foreign key (household_id, supersedes_handover_id)
    references public.handovers (household_id, id),
  add constraint handovers_author_identity_present_v2
    check (author_id is not null or author_actor_ref_id is not null),
  add constraint handovers_valid_window_v2
    check (valid_until is null or valid_from is null or valid_until >= valid_from);

update public.handovers set valid_from = created_at where valid_from is null;
alter table public.handovers alter column valid_from set not null;

-- ---------------------------------------------------------------------------
-- Production-only notification / Google-write hard boundary
-- ---------------------------------------------------------------------------

alter table public.user_notifications
  add column recipient_actor_ref_id uuid null,
  add column notification_kind text null,
  add column urgency text not null default 'immediate'
    check (urgency in ('immediate', 'digest', 'in_app_only')),
  add column safety_class text not null default 'normal',
  add column bundle_key text null,
  add column business_expires_at timestamptz null,
  add column aggregate_type text null,
  add column aggregate_id uuid null,
  add column aggregate_revision bigint null,
  add column test_context_id uuid null,
  add foreign key (household_id, recipient_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  add constraint user_notifications_production_only_v2 check (test_context_id is null);

alter table private.notification_outbox
  add column test_context_id uuid null,
  add constraint notification_outbox_production_only_v2 check (test_context_id is null);

alter table private.google_write_operations
  add column test_context_id uuid null,
  add constraint google_write_operations_production_only_v2 check (test_context_id is null);

-- ---------------------------------------------------------------------------
-- DailyBrief schedule persistence readiness (inactive until later cutover)
-- ---------------------------------------------------------------------------

do $$
declare
  r record;
  v_name text;
  v_count int := 0;
  v_def text;
begin
  for r in
    select c.conname, pg_get_constraintdef(c.oid) as def
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public'
      and t.relname = 'household_routine_schedules'
      and c.contype = 'c'
  loop
    v_def := lower(r.def);
    if v_def like '%schedule_kind%'
       and v_def like '%daily_assignment%'
       and v_def like '%nonworkday_morning_digest%' then
      v_name := r.conname;
      v_count := v_count + 1;
    end if;
  end loop;

  if v_count <> 1 then
    raise exception 'CURRENT_ROUTINE_SCHEDULE_KIND_CHECK_DRIFT count=%', v_count;
  end if;
  execute format('alter table public.household_routine_schedules drop constraint %I', v_name);
end;
$$;

alter table public.household_routine_schedules
  add constraint household_routine_schedules_kind_v2
  check (
    schedule_kind in (
      'daily_assignment',
      'dropoff_checklist', 'dropoff_checkin',
      'pickup_checklist', 'pickup_checkin',
      'nonpickup_evening_checklist', 'nonpickup_evening_checkin',
      'nonworkday_morning_digest', 'nonworkday_checkin',
      'weekday_morning_brief', 'nonworkday_morning_brief', 'evening_brief'
    )
  );

create table public.household_routine_schedule_overrides (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  local_date date not null,
  brief_kind text not null
    check (brief_kind in ('weekday_morning_brief', 'nonworkday_morning_brief', 'evening_brief')),
  enabled boolean not null default true,
  local_time time null,
  revision bigint not null default 1 check (revision >= 1),
  updated_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, local_date, brief_kind),
  foreign key (household_id, updated_by)
    references public.household_members (household_id, user_id)
);

create trigger set_updated_at
  before update on public.household_routine_schedule_overrides
  for each row execute function public.set_updated_at();

alter table public.household_routine_schedule_overrides enable row level security;
grant select on public.household_routine_schedule_overrides to authenticated;
create policy household_routine_schedule_overrides_select
  on public.household_routine_schedule_overrides
  for select to authenticated
  using (public.is_household_member(household_id));

-- ---------------------------------------------------------------------------
-- Canonical helper: ActorRef -> legacy real-user mirror, never substitution
-- ---------------------------------------------------------------------------

create or replace function private.fn_legacy_user_for_actor_ref_v1(
  p_household_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid
) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare
  v_kind text;
  v_real_user_id uuid;
begin
  perform private.fn_assert_actor_ref_scope(p_household_id, p_actor_ref_id, p_test_context_id);
  select actor_kind, real_user_id into v_kind, v_real_user_id
  from public.domain_actor_refs
  where household_id = p_household_id and id = p_actor_ref_id;
  if not found then raise exception 'ACTOR_REF_NOT_IN_HOUSEHOLD'; end if;
  if v_kind = 'real_user' then return v_real_user_id; end if;
  return null;
end;
$$;
revoke all on function private.fn_legacy_user_for_actor_ref_v1(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function private.fn_legacy_user_for_actor_ref_v1(uuid, uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Canonical operation receipt claim/replay helpers
-- ---------------------------------------------------------------------------

create or replace function private.fn_canonical_request_hash_v1(p_payload jsonb)
returns text language sql immutable security invoker set search_path = '' as $$
  select encode(sha256(convert_to(coalesce(p_payload, '{}'::jsonb)::text, 'UTF8')), 'hex');
$$;
revoke all on function private.fn_canonical_request_hash_v1(jsonb) from public, anon, authenticated;
grant execute on function private.fn_canonical_request_hash_v1(jsonb) to service_role;

create or replace function private.fn_claim_canonical_operation_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_operation_id uuid,
  p_action_type text,
  p_request_hash text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_inserted_id uuid;
  v_receipt private.canonical_operation_receipts%rowtype;
begin
  perform private.fn_validate_execution_context_v1(
    p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id
  );

  insert into private.canonical_operation_receipts (
    household_id, operator_user_id, actor_ref_id, test_context_id,
    operation_id, action_type, request_hash
  ) values (
    p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
    p_operation_id, p_action_type, p_request_hash
  ) on conflict do nothing returning id into v_inserted_id;

  if v_inserted_id is not null then
    return jsonb_build_object('disposition', 'claimed', 'receipt_id', v_inserted_id);
  end if;

  select * into v_receipt
  from private.canonical_operation_receipts r
  where r.actor_ref_id = p_actor_ref_id
    and r.operation_id = p_operation_id
    and r.test_context_id is not distinct from p_test_context_id
  for update;

  if not found then raise exception 'CANONICAL_OPERATION_RECEIPT_NOT_FOUND'; end if;
  if v_receipt.action_type is distinct from p_action_type
     or v_receipt.request_hash is distinct from p_request_hash then
    raise exception 'IDEMPOTENCY_CONFLICT';
  end if;
  if v_receipt.completed_at is not null then
    return jsonb_build_object(
      'disposition', 'replay',
      'receipt_id', v_receipt.id,
      'result_type', v_receipt.result_type,
      'result_id', v_receipt.result_id,
      'result_payload', v_receipt.result_payload
    );
  end if;
  raise exception 'OPERATION_IN_PROGRESS';
end;
$$;
revoke all on function private.fn_claim_canonical_operation_v1(uuid, uuid, uuid, uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function private.fn_claim_canonical_operation_v1(uuid, uuid, uuid, uuid, uuid, text, text) to service_role;

create or replace function private.fn_complete_canonical_operation_v1(
  p_receipt_id uuid,
  p_result_type text,
  p_result_id uuid,
  p_result_payload jsonb
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update private.canonical_operation_receipts
  set result_type = p_result_type,
      result_id = p_result_id,
      result_payload = coalesce(p_result_payload, '{}'::jsonb),
      completed_at = now()
  where id = p_receipt_id and completed_at is null;
  if not found then raise exception 'CANONICAL_OPERATION_RECEIPT_ALREADY_COMPLETED_OR_MISSING'; end if;
end;
$$;
revoke all on function private.fn_complete_canonical_operation_v1(uuid, text, uuid, jsonb) from public, anon, authenticated;
grant execute on function private.fn_complete_canonical_operation_v1(uuid, text, uuid, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- Side-effect adapter boundary + notification intent hook
-- ---------------------------------------------------------------------------

create or replace function private.fn_assert_external_effect_allowed_v1(
  p_effect_kind text,
  p_test_context_id uuid
) returns void
language plpgsql immutable security invoker set search_path = '' as $$
begin
  if p_test_context_id is not null
     and p_effect_kind in ('production_line', 'google_write', 'real_consent', 'production_analytics') then
    raise exception 'TEST_SIDE_EFFECT_FORBIDDEN';
  end if;
  if p_test_context_id is null and p_effect_kind = 'test_delivery' then
    raise exception 'TEST_DELIVERY_REQUIRES_TEST_CONTEXT';
  end if;
end;
$$;
revoke all on function private.fn_assert_external_effect_allowed_v1(text, uuid) from public, anon, authenticated;
grant execute on function private.fn_assert_external_effect_allowed_v1(text, uuid) to service_role;

create or replace function private.fn_emit_notification_intent_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_initiator_actor_ref_id uuid,
  p_test_context_id uuid,
  p_recipient_actor_ref_id uuid,
  p_notification_kind text,
  p_title text,
  p_body text,
  p_payload jsonb,
  p_dedup_key text,
  p_urgency text default 'immediate',
  p_safety_class text default 'normal',
  p_bundle_key text default null,
  p_business_expires_at timestamptz default null,
  p_aggregate_type text default null,
  p_aggregate_id uuid default null,
  p_aggregate_revision bigint default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_mode text;
  v_recipient_kind text;
  v_recipient_real_user_id uuid;
  v_simulated_role text;
  v_result_id uuid;
  v_prefix text;
begin
  v_mode := private.fn_validate_execution_context_v1(
    p_household_id, p_operator_user_id, p_initiator_actor_ref_id, p_test_context_id
  )->>'mode';
  perform private.fn_assert_actor_ref_scope(p_household_id, p_recipient_actor_ref_id, p_test_context_id);

  select actor_kind, real_user_id, simulated_role
    into v_recipient_kind, v_recipient_real_user_id, v_simulated_role
  from public.domain_actor_refs
  where household_id = p_household_id and id = p_recipient_actor_ref_id;
  if not found then raise exception 'NOTIFICATION_RECIPIENT_ACTOR_NOT_FOUND'; end if;

  if v_mode = 'test_simulation' then
    perform private.fn_assert_external_effect_allowed_v1('test_delivery', p_test_context_id);
    v_prefix := case
      when v_recipient_kind = 'simulated_member' and v_simulated_role = 'mama' then '🧪 テスト: ママへの通知'
      when v_recipient_kind = 'simulated_member' and v_simulated_role = 'papa' then '🧪 テスト: パパへの通知'
      else '🧪 テスト: 通知'
    end;
    insert into private.test_delivery_outbox (
      household_id, test_context_id, operator_user_id, semantic_actor_ref_id,
      rendered_payload, dedup_key
    ) values (
      p_household_id, p_test_context_id, p_operator_user_id, p_recipient_actor_ref_id,
      jsonb_build_object(
        'text', v_prefix || E'\n' || p_title || E'\n' || p_body,
        'notification_kind', p_notification_kind,
        'payload', coalesce(p_payload, '{}'::jsonb),
        'aggregate_type', p_aggregate_type,
        'aggregate_id', p_aggregate_id,
        'aggregate_revision', p_aggregate_revision
      ),
      p_dedup_key
    )
    on conflict (test_context_id, dedup_key) do update
      set rendered_payload = excluded.rendered_payload, updated_at = now()
    returning id into v_result_id;
    return v_result_id;
  end if;

  perform private.fn_assert_external_effect_allowed_v1('production_line', null);
  if v_recipient_kind <> 'real_user' or v_recipient_real_user_id is null then
    raise exception 'PRODUCTION_NOTIFICATION_REQUIRES_REAL_RECIPIENT';
  end if;

  insert into public.user_notifications (
    household_id, recipient_user_id, type, title, body, payload, dedup_key,
    recipient_actor_ref_id, notification_kind, urgency, safety_class, bundle_key,
    business_expires_at, aggregate_type, aggregate_id, aggregate_revision, test_context_id
  ) values (
    p_household_id, v_recipient_real_user_id, p_notification_kind, p_title, p_body,
    coalesce(p_payload, '{}'::jsonb), p_dedup_key, p_recipient_actor_ref_id,
    p_notification_kind, p_urgency, p_safety_class, p_bundle_key,
    p_business_expires_at, p_aggregate_type, p_aggregate_id, p_aggregate_revision, null
  ) on conflict (recipient_user_id, dedup_key) do nothing
  returning id into v_result_id;

  if v_result_id is null then
    select id into v_result_id from public.user_notifications
    where recipient_user_id = v_recipient_real_user_id and dedup_key = p_dedup_key;
  end if;
  return v_result_id;
end;
$$;
revoke all on function private.fn_emit_notification_intent_v1(
  uuid, uuid, uuid, uuid, uuid, text, text, text, jsonb, text,
  text, text, text, timestamptz, text, uuid, bigint
) from public, anon, authenticated;
grant execute on function private.fn_emit_notification_intent_v1(
  uuid, uuid, uuid, uuid, uuid, text, text, text, jsonb, text,
  text, text, text, timestamptz, text, uuid, bigint
) to service_role;

-- ---------------------------------------------------------------------------
-- Request Attempt -> CURRENT legacy lifecycle tuple compatibility helper
-- ---------------------------------------------------------------------------

create or replace function private.fn_project_request_legacy_lifecycle_v1(
  p_household_id uuid,
  p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_request public.requests%rowtype;
  v_attempt public.request_attempts%rowtype;
  v_agreement public.request_attempts%rowtype;
  v_has_nonlegacy boolean;
  v_status text;
  v_accepted_at timestamptz;
  v_declined_at timestamptz;
  v_cancelled_at timestamptz;
  v_completed_at timestamptz;
begin
  select * into v_request from public.requests
  where household_id = p_household_id and id = p_request_id for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;

  select exists (
    select 1 from public.request_attempts a
    where a.household_id = p_household_id and a.request_id = p_request_id and not a.legacy_backfill
  ) into v_has_nonlegacy;

  if v_request.status = 'completed' and not v_has_nonlegacy then
    return jsonb_build_object(
      'status', v_request.status,
      'accepted_at', v_request.accepted_at,
      'declined_at', v_request.declined_at,
      'cancelled_at', v_request.cancelled_at,
      'completed_at', v_request.completed_at,
      'preserved_historical_completed', true
    );
  end if;

  select a.* into v_agreement
  from public.request_attempts a
  where a.household_id = p_household_id
    and a.request_id = p_request_id
    and a.attempt_kind in ('initial', 'reproposal')
    and a.state = 'accepted'
  order by a.accepted_at asc nulls last, a.created_at asc
  limit 1;

  if found then
    v_status := 'accepted';
    v_accepted_at := v_agreement.accepted_at;
  else
    select a.* into v_attempt
    from public.request_attempts a
    where a.household_id = p_household_id
      and a.request_id = p_request_id
      and a.attempt_kind in ('initial', 'reproposal')
    order by (a.state in ('pending', 'checking', 'consulting', 'awaiting_confirmation')) desc,
             a.created_at desc
    limit 1;
    if not found then raise exception 'REQUEST_ATTEMPT_NOT_FOUND'; end if;

    case v_attempt.state
      when 'pending' then v_status := 'pending';
      when 'checking' then v_status := 'pending';
      when 'consulting' then v_status := 'pending';
      when 'awaiting_confirmation' then v_status := 'pending';
      when 'accepted' then v_status := 'accepted'; v_accepted_at := v_attempt.accepted_at;
      when 'declined' then v_status := 'declined'; v_declined_at := v_attempt.declined_at;
      when 'expired' then v_status := 'cancelled'; v_cancelled_at := v_attempt.expired_at;
      when 'cancelled' then v_status := 'cancelled'; v_cancelled_at := v_attempt.cancelled_at;
      else raise exception 'REQUEST_ATTEMPT_STATE_UNPROJECTABLE';
    end case;
  end if;

  update public.requests
  set status = v_status,
      accepted_at = v_accepted_at,
      declined_at = v_declined_at,
      cancelled_at = v_cancelled_at,
      completed_at = v_completed_at,
      revision = revision + 1,
      closed_at = case
        when v_status in ('declined', 'cancelled') then coalesce(v_declined_at, v_cancelled_at)
        else closed_at
      end
  where household_id = p_household_id and id = p_request_id;

  return jsonb_build_object(
    'status', v_status,
    'accepted_at', v_accepted_at,
    'declined_at', v_declined_at,
    'cancelled_at', v_cancelled_at,
    'completed_at', v_completed_at
  );
end;
$$;
revoke all on function private.fn_project_request_legacy_lifecycle_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function private.fn_project_request_legacy_lifecycle_v1(uuid, uuid) to service_role;

grant select, insert, update, delete on public.household_routine_schedule_overrides to service_role;

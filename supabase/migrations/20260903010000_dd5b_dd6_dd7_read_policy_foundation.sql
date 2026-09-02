-- WP-DD5B / WP-DD6 / WP-DD7 parallel-worker foundation.
--
-- This migration is intentionally R0/additive with one bounded CHECK evolution.
-- It does NOT activate a canonical shopping writer, Request writer, Task writer,
-- DailyBrief dispatcher, or production notification sender.  Those aggregate
-- cutovers remain atomic/P1-gated per docs/design/current/02 and /07.
--
-- Safe independent pieces implemented here:
--   * Shopping actual/audit evidence (ActorRef + direct test context)
--   * DailyBrief schedule kinds + per-date override representation
--   * Notification intent metadata required by the accepted policy contract
--   * A side-effect-free notification policy resolver
--   * A side-effect-free server DailyBrief read model, including Google all-day
--     occurrences without manufacturing 00:00 timestamps

-- ---------------------------------------------------------------------------
-- DD5B: shopping actual/history evidence.  Current shopping_items remains the
-- operational snapshot.  Writers are deliberately not switched in this batch.
-- ---------------------------------------------------------------------------

create table public.shopping_actual_participants (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  shopping_item_id uuid not null,
  actor_ref_id uuid not null,
  participation_kind text not null default 'performed'
    check (participation_kind = 'performed'),
  recorded_by_actor_ref_id uuid null,
  recorded_at timestamptz not null default now(),
  removed_at timestamptz null,
  removed_by_actor_ref_id uuid null,
  source text not null default 'canonical'
    check (source in ('canonical', 'legacy_backfill')),
  test_context_id uuid null,
  created_at timestamptz not null default now(),
  unique (household_id, id),
  foreign key (household_id, shopping_item_id)
    references public.shopping_items (household_id, id),
  foreign key (household_id, actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  foreign key (household_id, recorded_by_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  foreign key (household_id, removed_by_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id),
  check (
    (removed_at is null and removed_by_actor_ref_id is null)
    or (removed_at is not null and removed_by_actor_ref_id is not null)
  )
);

create unique index shopping_actual_participants_active_actor_idx
  on public.shopping_actual_participants (shopping_item_id, actor_ref_id)
  where removed_at is null;
create index shopping_actual_participants_item_idx
  on public.shopping_actual_participants (household_id, shopping_item_id, recorded_at);
create index shopping_actual_participants_test_context_idx
  on public.shopping_actual_participants (test_context_id)
  where test_context_id is not null;

create table public.shopping_events (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  shopping_item_id uuid not null,
  actor_ref_id uuid null,
  event_type text not null check (event_type in (
    'assignment_changed',
    'claim_acquired', 'claim_released', 'claim_taken_over',
    'status_changed', 'actual_recorded', 'actual_corrected'
  )),
  aggregate_revision bigint not null check (aggregate_revision >= 1),
  payload jsonb not null default '{}'::jsonb,
  source text not null default 'canonical',
  operation_id uuid null,
  test_context_id uuid null,
  created_at timestamptz not null default now(),
  foreign key (household_id, shopping_item_id)
    references public.shopping_items (household_id, id),
  foreign key (household_id, actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id)
);

create index shopping_events_item_idx
  on public.shopping_events (household_id, shopping_item_id, created_at desc);
create unique index shopping_events_operation_idx
  on public.shopping_events (shopping_item_id, operation_id, event_type)
  where operation_id is not null;
create index shopping_events_test_context_idx
  on public.shopping_events (test_context_id)
  where test_context_id is not null;

create or replace function private.fn_enforce_shopping_evidence_scope()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_parent_test_context_id uuid;
  v_actor_ref_id uuid;
begin
  select test_context_id into v_parent_test_context_id
  from public.shopping_items
  where household_id = new.household_id and id = new.shopping_item_id;

  if not found then
    raise exception 'CANONICAL_PARENT_NOT_FOUND';
  end if;
  if new.test_context_id is distinct from v_parent_test_context_id then
    raise exception 'TEST_CONTEXT_PARENT_MISMATCH';
  end if;

  if tg_table_name = 'shopping_actual_participants' then
    foreach v_actor_ref_id in array array[
      new.actor_ref_id,
      new.recorded_by_actor_ref_id,
      new.removed_by_actor_ref_id
    ] loop
      perform private.fn_assert_actor_ref_scope(
        new.household_id, v_actor_ref_id, new.test_context_id
      );
    end loop;
  else
    perform private.fn_assert_actor_ref_scope(
      new.household_id, new.actor_ref_id, new.test_context_id
    );
  end if;

  return new;
end;
$$;
revoke all on function private.fn_enforce_shopping_evidence_scope() from public, anon, authenticated;
grant execute on function private.fn_enforce_shopping_evidence_scope() to service_role;

create trigger shopping_actual_participants_scope_guard
  before insert or update of household_id, shopping_item_id, actor_ref_id,
    recorded_by_actor_ref_id, removed_by_actor_ref_id, test_context_id
  on public.shopping_actual_participants
  for each row execute function private.fn_enforce_shopping_evidence_scope();

create trigger shopping_events_scope_guard
  before insert or update of household_id, shopping_item_id, actor_ref_id, test_context_id
  on public.shopping_events
  for each row execute function private.fn_enforce_shopping_evidence_scope();

alter table public.shopping_actual_participants enable row level security;
grant select on public.shopping_actual_participants to authenticated;
create policy shopping_actual_participants_select on public.shopping_actual_participants
  for select to authenticated
  using (public.is_household_member(household_id) and test_context_id is null);

alter table public.shopping_events enable row level security;
grant select on public.shopping_events to authenticated;
create policy shopping_events_select on public.shopping_events
  for select to authenticated
  using (public.is_household_member(household_id) and test_context_id is null);

-- ---------------------------------------------------------------------------
-- DD6: canonical DailyBrief schedule representation.
-- Existing nine routine kinds remain valid until the atomic DailyBrief cadence
-- cutover. New kinds can be configured beforehand without disabling old rows.
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

  execute format(
    'alter table public.household_routine_schedules drop constraint %I',
    v_name
  );
end;
$$;

alter table public.household_routine_schedules
  add constraint household_routine_schedules_schedule_kind_v2_check
  check (schedule_kind in (
    'daily_assignment',
    'dropoff_checklist', 'dropoff_checkin',
    'pickup_checklist', 'pickup_checkin',
    'nonpickup_evening_checklist', 'nonpickup_evening_checkin',
    'nonworkday_morning_digest', 'nonworkday_checkin',
    'daily_brief_weekday_morning',
    'daily_brief_nonworkday_morning',
    'daily_brief_evening'
  ));

create table public.daily_brief_schedule_overrides (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  local_date date not null,
  schedule_kind text not null check (schedule_kind in (
    'daily_brief_weekday_morning',
    'daily_brief_nonworkday_morning',
    'daily_brief_evening'
  )),
  enabled boolean not null default true,
  local_time time null,
  updated_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, local_date, schedule_kind),
  foreign key (household_id, updated_by)
    references public.household_members (household_id, user_id),
  check (not enabled or local_time is not null)
);

create index daily_brief_schedule_overrides_due_idx
  on public.daily_brief_schedule_overrides (local_date, schedule_kind, enabled, local_time);

create trigger set_updated_at
  before update on public.daily_brief_schedule_overrides
  for each row execute function public.set_updated_at();

alter table public.daily_brief_schedule_overrides enable row level security;
grant select on public.daily_brief_schedule_overrides to authenticated;
create policy daily_brief_schedule_overrides_select on public.daily_brief_schedule_overrides
  for select to authenticated
  using (public.is_household_member(household_id));

-- ---------------------------------------------------------------------------
-- DD7: notification intent metadata.  Legacy type/priority remain compatibility
-- columns; no sender behavior changes in this migration.
-- ---------------------------------------------------------------------------

alter table public.user_notifications
  add column notification_kind text null,
  add column urgency text null
    check (urgency is null or urgency in ('immediate', 'digest', 'in_app_only')),
  add column safety_class text null,
  add column bundle_key text null,
  add column business_expires_at timestamptz null,
  add column test_context_id uuid null,
  add foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id);

create index user_notifications_intent_idx
  on public.user_notifications (
    household_id, recipient_user_id, notification_kind, urgency, created_at desc
  );
create index user_notifications_business_expiry_idx
  on public.user_notifications (business_expires_at)
  where business_expires_at is not null and read_at is null;
create index user_notifications_test_context_idx
  on public.user_notifications (test_context_id)
  where test_context_id is not null;

alter table private.notification_outbox
  add column notification_kind text null,
  add column urgency text null
    check (urgency is null or urgency in ('immediate', 'digest', 'in_app_only')),
  add column safety_class text null,
  add column bundle_key text null,
  add column test_context_id uuid null,
  add foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id);

create index notification_outbox_intent_idx
  on private.notification_outbox (
    household_id, recipient_user_id, notification_kind, urgency, status, created_at
  );
create index notification_outbox_test_context_idx
  on private.notification_outbox (test_context_id)
  where test_context_id is not null;

-- Pure policy resolver.  Mutation commands will create semantic intents and
-- call the same policy at their atomic cutover; current legacy writers are not
-- redirected in this worker.
create or replace function private.resolve_notification_policy(
  p_semantic_type text,
  p_reply_or_action_required boolean default false,
  p_deadline_at timestamptz default null,
  p_duplicate_sensitivity text default 'normal',
  p_attention_state text default 'active',
  p_next_check_at timestamptz default null,
  p_behavior_change_now boolean default false,
  p_preference_allows_line boolean default true,
  p_line_quota_allows_push boolean default true,
  p_is_stale boolean default false,
  p_test_context_id uuid default null,
  p_now timestamptz default now()
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_disposition text := 'next_digest';
  v_reason text := 'default_digest';
  v_priority text := 'normal';
  v_hard_deadline_risk boolean := false;
begin
  if p_duplicate_sensitivity not in ('normal', 'avoid_duplicate', 'safety_critical') then
    raise exception 'INVALID_DUPLICATE_SENSITIVITY';
  end if;
  if p_attention_state not in ('active', 'waiting') then
    raise exception 'INVALID_ATTENTION_STATE';
  end if;

  v_hard_deadline_risk := p_deadline_at is not null
    and p_deadline_at <= p_now + interval '2 hours';

  if p_is_stale then
    v_disposition := 'suppressed';
    v_reason := 'stale_intent';
  elsif p_test_context_id is not null then
    -- Test delivery is handled by the separate DD3A synthetic adapter, never
    -- by the production LINE policy/outbox.
    v_disposition := 'suppressed';
    v_reason := 'test_context_production_delivery_forbidden';
  elsif p_attention_state = 'waiting'
        and coalesce(p_next_check_at > p_now, false)
        and not v_hard_deadline_risk then
    v_disposition := 'suppressed';
    v_reason := 'waiting_before_next_check';
  elsif p_semantic_type in ('task_completed', 'shopping_completed')
        and p_duplicate_sensitivity = 'normal' then
    v_disposition := 'in_app_only';
    v_reason := 'normal_completion_no_immediate_push';
  elsif p_semantic_type in ('task_completed', 'shopping_completed', 'actual_corrected')
        and p_duplicate_sensitivity in ('avoid_duplicate', 'safety_critical')
        and p_behavior_change_now then
    v_disposition := 'immediate';
    v_reason := 'duplicate_sensitive_behavior_change';
    v_priority := case when p_duplicate_sensitivity = 'safety_critical' then 'critical' else 'normal' end;
  elsif p_reply_or_action_required
        or p_semantic_type in (
          'request_created', 'request_response', 'request_finalized',
          'assignment_negotiation_response', 'assignment_finalized',
          'important_schedule_change'
        ) then
    v_disposition := 'immediate';
    v_reason := 'action_or_coordination_required';
    v_priority := case when v_hard_deadline_risk then 'critical' else 'normal' end;
  elsif p_attention_state = 'waiting'
        and (coalesce(p_next_check_at <= p_now, false) or v_hard_deadline_risk) then
    v_disposition := case when v_hard_deadline_risk then 'immediate' else 'next_digest' end;
    v_reason := case when v_hard_deadline_risk then 'waiting_hard_deadline_risk' else 'waiting_check_due' end;
    v_priority := case when v_hard_deadline_risk then 'critical' else 'reminder' end;
  elsif p_semantic_type in ('minor_assignment_change', 'waiting_check_due') then
    v_disposition := 'next_digest';
    v_reason := 'digest_preferred';
    v_priority := 'reminder';
  elsif p_semantic_type in ('analysis', 'history') then
    v_disposition := 'suppressed';
    v_reason := 'non_proactive_semantic';
  end if;

  if v_disposition = 'immediate' and not p_preference_allows_line then
    v_disposition := 'in_app_only';
    v_reason := 'recipient_preference';
  elsif v_disposition = 'immediate' and not p_line_quota_allows_push then
    v_disposition := 'in_app_only';
    v_reason := 'line_quota_preserved';
  end if;

  return jsonb_build_object(
    'disposition', v_disposition,
    'reason', v_reason,
    'priority', v_priority,
    'hard_deadline_risk', v_hard_deadline_risk
  );
end;
$$;

revoke all on function private.resolve_notification_policy(
  text, boolean, timestamptz, text, text, timestamptz, boolean,
  boolean, boolean, boolean, uuid, timestamptz
) from public, anon, authenticated;
grant execute on function private.resolve_notification_policy(
  text, boolean, timestamptz, text, text, timestamptz, boolean,
  boolean, boolean, boolean, uuid, timestamptz
) to service_role;

-- ---------------------------------------------------------------------------
-- DD6: shared server DailyBrief read model.
--
-- Read-only and production-only.  It understands canonical fields when they
-- are populated, with deterministic legacy fallback while aggregate cutovers
-- are still pending.  No read path here writes/resumes/completes anything.
-- ---------------------------------------------------------------------------

create or replace function public.server_read_daily_brief(
  p_actor_id uuid,
  p_local_date date default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_date date := coalesce(p_local_date, (now() at time zone 'Asia/Tokyo')::date);
  v_start timestamptz;
  v_end timestamptz;
  v_daypart text;
  v_urgent_actions jsonb;
  v_exceptions jsonb;
  v_active_infos jsonb;
  v_already_handled jsonb;
  v_morning jsonb;
  v_daytime jsonb;
  v_evening jsonb;
  v_partner_summary jsonb;
  v_carryovers jsonb;
  v_waiting_checks jsonb;
  v_reconciliation jsonb;
  v_schedule jsonb;
  v_shopping jsonb;
begin
  if p_actor_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;
  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  select id into v_actor_ref_id
  from public.domain_actor_refs
  where household_id = v_household_id
    and actor_kind = 'real_user'
    and real_user_id = p_actor_id;

  v_start := (v_date::timestamp at time zone 'Asia/Tokyo');
  v_end := ((v_date + 1)::timestamp at time zone 'Asia/Tokyo');
  v_daypart := case
    when (now() at time zone 'Asia/Tokyo')::time < time '11:30' then 'morning'
    when (now() at time zone 'Asia/Tokyo')::time < time '17:00' then 'daytime'
    else 'evening'
  end;

  -- Requests requiring a response and unassigned actionable work are the
  -- highest-priority operational actions.  Canonical Attempt state wins when
  -- present; legacy pending is a deterministic compatibility fallback.
  select coalesce(jsonb_agg(x.item order by x.sort_at nulls last, x.sort_key), '[]'::jsonb)
  into v_urgent_actions
  from (
    select
      coalesce(ra.reply_due_at, r.due_at) as sort_at,
      'request:' || r.id::text as sort_key,
      jsonb_build_object(
        'kind', 'request',
        'request_id', r.id,
        'attempt_id', ra.id,
        'state', coalesce(ra.state, r.status),
        'title', r.shared_title,
        'message', r.shared_message,
        'reply_due_at', coalesce(ra.reply_due_at, r.due_at),
        'action_target', jsonb_build_object(
          'kind', 'request',
          'request_id', r.id,
          'attempt_id', ra.id,
          'revision', coalesce(ra.revision, r.revision)
        )
      ) as item
    from public.requests r
    left join lateral (
      select a.id, a.state, a.reply_due_at, a.revision
      from public.request_attempts a
      where a.household_id = r.household_id
        and a.request_id = r.id
        and a.test_context_id is null
        and a.state in ('pending', 'checking', 'consulting', 'awaiting_confirmation')
      order by a.created_at desc
      limit 1
    ) ra on true
    where r.household_id = v_household_id
      and r.test_context_id is null
      and (
        (v_actor_ref_id is not null and r.recipient_actor_ref_id = v_actor_ref_id)
        or (r.recipient_actor_ref_id is null and r.recipient_id = p_actor_id)
      )
      and (ra.id is not null or r.status = 'pending')

    union all

    select
      ti.due_at as sort_at,
      'task:' || ti.id::text as sort_key,
      jsonb_build_object(
        'kind', 'unassigned_task',
        'task_id', ti.id,
        'title', ti.title,
        'due_at', ti.due_at,
        'duplicate_sensitivity', coalesce(ti.duplicate_sensitivity, 'normal'),
        'action_target', jsonb_build_object(
          'kind', 'task', 'task_id', ti.id, 'revision', ti.revision
        )
      ) as item
    from public.task_instances ti
    where ti.household_id = v_household_id
      and ti.test_context_id is null
      and ti.scheduled_date = v_date
      and ti.status in ('todo', 'in_progress')
      and ti.attention_state = 'active'
      and ti.assignment_mode = 'unassigned'
  ) x;

  -- Exceptions are intentionally narrow: actual timed assignment conflicts.
  -- All-day Google events never enter this predicate.
  select coalesce(jsonb_agg(jsonb_build_object(
    'kind', 'assignment_conflict',
    'task_id', ti.id,
    'title', ti.title,
    'due_at', ti.due_at,
    'action_target', jsonb_build_object(
      'kind', 'task', 'task_id', ti.id, 'revision', ti.revision
    )
  ) order by ti.due_at), '[]'::jsonb)
  into v_exceptions
  from public.task_instances ti
  left join public.recurrence_rules rr
    on rr.household_id = ti.household_id and rr.id = ti.recurrence_rule_id
  where ti.household_id = v_household_id
    and ti.test_context_id is null
    and ti.scheduled_date = v_date
    and ti.status in ('todo', 'in_progress')
    and ti.attention_state = 'active'
    and ti.planned_assignee_id = p_actor_id
    and ti.due_at is not null
    and private.fn_calendar_conflict_exists(
      ti.household_id,
      ti.planned_assignee_id,
      ti.due_at,
      coalesce(rr.conflict_window_minutes, 60)
    );

  -- Legacy handovers remain readable until their aggregate cutover.  Canonical
  -- ActorRef acknowledgement is preferred, then legacy handover_reads fallback.
  select coalesce(jsonb_agg(jsonb_build_object(
    'kind', 'info',
    'handover_id', h.id,
    'text', h.shared_text,
    'period', h.period,
    'occurred_on', h.occurred_on,
    'action_target', jsonb_build_object('kind', 'info', 'handover_id', h.id)
  ) order by h.created_at desc), '[]'::jsonb)
  into v_active_infos
  from public.handovers h
  where h.household_id = v_household_id
    and h.test_context_id is null
    and h.occurred_on between v_date - 7 and v_date
    and not exists (
      select 1
      from public.info_acknowledgements ia
      where ia.household_id = h.household_id
        and ia.handover_id = h.id
        and ia.test_context_id is null
        and v_actor_ref_id is not null
        and ia.actor_ref_id = v_actor_ref_id
    )
    and not exists (
      select 1
      from public.handover_reads hr
      where hr.household_id = h.household_id
        and hr.handover_id = h.id
        and hr.user_id = p_actor_id
    );

  -- "Already handled" is deliberately limited to duplicate-sensitive work,
  -- where seeing completion can prevent duplicate action. Normal completed
  -- chores collapse out of this section.
  select coalesce(jsonb_agg(jsonb_build_object(
    'kind', 'task',
    'task_id', ti.id,
    'title', ti.title,
    'completed_at', ti.completed_at,
    'duplicate_sensitivity', ti.duplicate_sensitivity,
    'action_target', jsonb_build_object(
      'kind', 'task', 'task_id', ti.id, 'revision', ti.revision
    )
  ) order by ti.completed_at desc), '[]'::jsonb)
  into v_already_handled
  from public.task_instances ti
  where ti.household_id = v_household_id
    and ti.test_context_id is null
    and ti.scheduled_date = v_date
    and ti.status = 'completed'
    and ti.duplicate_sensitivity in ('avoid_duplicate', 'safety_critical');

  -- Own active tasks.  Canonical person/claim identity wins; null canonical
  -- assignment keeps the legacy mirror readable during R0/R1 migration.
  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id', ti.id,
    'title', ti.title,
    'status', ti.status,
    'due_at', ti.due_at,
    'expectation', coalesce(ti.expectation, 'normal'),
    'assignment_mode', coalesce(ti.assignment_mode,
      case when ti.planned_assignee_id is null then 'unassigned' else 'person' end),
    'revision', ti.revision,
    'action_target', jsonb_build_object(
      'kind', 'task', 'task_id', ti.id, 'revision', ti.revision
    )
  ) order by ti.due_at nulls last, ti.title), '[]'::jsonb)
  into v_morning
  from public.task_instances ti
  where ti.household_id = v_household_id
    and ti.test_context_id is null
    and ti.scheduled_date = v_date
    and ti.status in ('todo', 'in_progress')
    and ti.attention_state = 'active'
    and coalesce(ti.routine_phase, 'anytime') = 'morning'
    and (
      (v_actor_ref_id is not null and ti.planned_assignee_actor_ref_id = v_actor_ref_id)
      or (ti.planned_assignee_actor_ref_id is null and ti.planned_assignee_id = p_actor_id)
      or (v_actor_ref_id is not null and ti.active_claimant_actor_ref_id = v_actor_ref_id)
    );

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id', ti.id,
    'title', ti.title,
    'status', ti.status,
    'due_at', ti.due_at,
    'expectation', coalesce(ti.expectation, 'normal'),
    'assignment_mode', coalesce(ti.assignment_mode,
      case when ti.planned_assignee_id is null then 'unassigned' else 'person' end),
    'revision', ti.revision,
    'action_target', jsonb_build_object(
      'kind', 'task', 'task_id', ti.id, 'revision', ti.revision
    )
  ) order by ti.due_at nulls last, ti.title), '[]'::jsonb)
  into v_daytime
  from public.task_instances ti
  where ti.household_id = v_household_id
    and ti.test_context_id is null
    and ti.scheduled_date = v_date
    and ti.status in ('todo', 'in_progress')
    and ti.attention_state = 'active'
    and coalesce(ti.routine_phase, 'anytime') not in ('morning', 'evening')
    and (
      (v_actor_ref_id is not null and ti.planned_assignee_actor_ref_id = v_actor_ref_id)
      or (ti.planned_assignee_actor_ref_id is null and ti.planned_assignee_id = p_actor_id)
      or (v_actor_ref_id is not null and ti.active_claimant_actor_ref_id = v_actor_ref_id)
    );

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id', ti.id,
    'title', ti.title,
    'status', ti.status,
    'due_at', ti.due_at,
    'expectation', coalesce(ti.expectation, 'normal'),
    'assignment_mode', coalesce(ti.assignment_mode,
      case when ti.planned_assignee_id is null then 'unassigned' else 'person' end),
    'revision', ti.revision,
    'action_target', jsonb_build_object(
      'kind', 'task', 'task_id', ti.id, 'revision', ti.revision
    )
  ) order by ti.due_at nulls last, ti.title), '[]'::jsonb)
  into v_evening
  from public.task_instances ti
  where ti.household_id = v_household_id
    and ti.test_context_id is null
    and ti.scheduled_date = v_date
    and ti.status in ('todo', 'in_progress')
    and ti.attention_state = 'active'
    and ti.routine_phase = 'evening'
    and (
      (v_actor_ref_id is not null and ti.planned_assignee_actor_ref_id = v_actor_ref_id)
      or (ti.planned_assignee_actor_ref_id is null and ti.planned_assignee_id = p_actor_id)
      or (v_actor_ref_id is not null and ti.active_claimant_actor_ref_id = v_actor_ref_id)
    );

  select jsonb_build_object(
    'open_count', count(*),
    'household_critical', coalesce(jsonb_agg(jsonb_build_object(
      'task_id', ti.id,
      'title', ti.title,
      'due_at', ti.due_at,
      'duplicate_sensitivity', coalesce(ti.duplicate_sensitivity, 'normal'),
      'action_target', jsonb_build_object(
        'kind', 'task', 'task_id', ti.id, 'revision', ti.revision
      )
    ) order by ti.due_at nulls last) filter (
      where ti.duplicate_sensitivity in ('avoid_duplicate', 'safety_critical')
         or ti.category in ('transport', 'medication', 'health', 'submission')
    ), '[]'::jsonb)
  )
  into v_partner_summary
  from public.task_instances ti
  where ti.household_id = v_household_id
    and ti.test_context_id is null
    and ti.scheduled_date = v_date
    and ti.status in ('todo', 'in_progress')
    and ti.attention_state = 'active'
    and ti.planned_assignee_id is not null
    and ti.planned_assignee_id <> p_actor_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id', ti.id,
    'title', ti.title,
    'scheduled_date', ti.scheduled_date,
    'due_at', ti.due_at,
    'carryover_policy', ti.carryover_policy,
    'result_certainty', case
      when ti.carryover_policy in ('until_done', 'until_deadline') then 'confirmed_open'
      else 'result_unknown'
    end,
    'action_target', jsonb_build_object(
      'kind', 'task', 'task_id', ti.id, 'revision', ti.revision
    )
  ) order by ti.scheduled_date desc, ti.due_at nulls last), '[]'::jsonb)
  into v_carryovers
  from public.task_instances ti
  where ti.household_id = v_household_id
    and ti.test_context_id is null
    and ti.scheduled_date < v_date
    and ti.status in ('todo', 'in_progress')
    and (
      ti.carryover_policy in ('until_done', 'until_deadline')
      or (
        ti.carryover_policy is null
        and ti.task_kind = 'evening_chore'
        and ti.scheduled_date = v_date - 1
      )
    )
    and (
      (v_actor_ref_id is not null and ti.planned_assignee_actor_ref_id = v_actor_ref_id)
      or (ti.planned_assignee_actor_ref_id is null and ti.planned_assignee_id = p_actor_id)
      or (v_actor_ref_id is not null and ti.active_claimant_actor_ref_id = v_actor_ref_id)
    );

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id', ti.id,
    'title', ti.title,
    'waiting_note', ti.waiting_note,
    'next_check_at', ti.next_check_at,
    'due_at', ti.due_at,
    'hard_deadline_risk', ti.due_at is not null and ti.due_at < v_end,
    'action_target', jsonb_build_object(
      'kind', 'task', 'task_id', ti.id, 'revision', ti.revision
    )
  ) order by ti.next_check_at nulls last, ti.due_at nulls last), '[]'::jsonb)
  into v_waiting_checks
  from public.task_instances ti
  where ti.household_id = v_household_id
    and ti.test_context_id is null
    and ti.status in ('todo', 'in_progress')
    and ti.attention_state = 'waiting'
    and (
      (ti.next_check_at is not null and ti.next_check_at < v_end)
      or (ti.due_at is not null and ti.due_at < v_end)
    )
    and (
      (v_actor_ref_id is not null and ti.planned_assignee_actor_ref_id = v_actor_ref_id)
      or (ti.planned_assignee_actor_ref_id is null and ti.planned_assignee_id = p_actor_id)
      or (v_actor_ref_id is not null and ti.active_claimant_actor_ref_id = v_actor_ref_id)
    );

  select jsonb_build_object(
    'eligible_count', count(*),
    'action_target', case when count(*) > 0 then jsonb_build_object(
      'kind', 'reconciliation', 'local_date', v_date
    ) else null end
  )
  into v_reconciliation
  from public.task_instances ti
  where ti.household_id = v_household_id
    and ti.test_context_id is null
    and ti.scheduled_date = v_date
    and ti.status in ('todo', 'in_progress')
    and ti.attention_state = 'active'
    and coalesce(ti.expectation, 'normal') in ('required', 'normal')
    and (
      (v_actor_ref_id is not null and ti.planned_assignee_actor_ref_id = v_actor_ref_id)
      or (ti.planned_assignee_actor_ref_id is null and ti.planned_assignee_id = p_actor_id)
      or (v_actor_ref_id is not null and ti.active_claimant_actor_ref_id = v_actor_ref_id)
    );

  -- Google all-day entries are returned with starts_at/ends_at NULL and the
  -- original date range. Timed entries keep timestamps. No all-day entry is
  -- passed to the timed conflict predicate.
  select coalesce(jsonb_agg(s.item order by s.sort_key, s.title), '[]'::jsonb)
  into v_schedule
  from (
    select
      case when occ.all_day_start is not null then 0 else 1 end as sort_key,
      coalesce(occ.title, '') as title,
      jsonb_build_object(
        'kind', 'google_occurrence',
        'occurrence_key', occ.occurrence_key,
        'title', occ.title,
        'is_all_day', occ.all_day_start is not null,
        'starts_at', case when occ.all_day_start is null then to_jsonb(occ.starts_at) else 'null'::jsonb end,
        'ends_at', case when occ.all_day_start is null then to_jsonb(occ.ends_at) else 'null'::jsonb end,
        'all_day_start', occ.all_day_start,
        'all_day_end_exclusive', occ.all_day_end_exclusive,
        'busy_user_ids', (
          select coalesce(jsonb_agg(bm.user_id order by bm.user_id), '[]'::jsonb)
          from public.calendar_occurrence_busy_members bm
          where bm.household_id = occ.household_id
            and bm.calendar_connection_id = occ.calendar_connection_id
            and bm.occurrence_key = occ.occurrence_key
        ),
        'action_target', jsonb_build_object(
          'kind', 'calendar_occurrence', 'occurrence_key', occ.occurrence_key
        )
      ) as item
    from public.calendar_event_occurrences occ
    join public.calendar_connections cc
      on cc.household_id = occ.household_id
     and cc.id = occ.calendar_connection_id
    where occ.household_id = v_household_id
      and cc.active
      and occ.status <> 'cancelled'
      and coalesce(occ.transparency, 'opaque') <> 'transparent'
      and (
        (
          occ.all_day_start is not null
          and occ.all_day_start <= v_date
          and coalesce(occ.all_day_end_exclusive, occ.all_day_start + 1) > v_date
        )
        or (
          occ.all_day_start is null
          and occ.starts_at is not null
          and (occ.starts_at at time zone 'Asia/Tokyo')::date = v_date
        )
      )

    union all

    select
      2 as sort_key,
      ti.title,
      jsonb_build_object(
        'kind', 'task_due',
        'task_id', ti.id,
        'title', ti.title,
        'is_all_day', false,
        'starts_at', ti.due_at,
        'ends_at', ti.calendar_ends_at,
        'all_day_start', null,
        'all_day_end_exclusive', null,
        'action_target', jsonb_build_object(
          'kind', 'task', 'task_id', ti.id, 'revision', ti.revision
        )
      ) as item
    from public.task_instances ti
    where ti.household_id = v_household_id
      and ti.test_context_id is null
      and ti.scheduled_date = v_date
      and ti.status in ('todo', 'in_progress')
      and ti.due_at is not null
  ) s;

  -- Shopping stays a distinct semantic section while still sharing the same
  -- server read.  Canonical assignment/claim fields are exposed with legacy
  -- fallback; no new writer semantics are enabled here.
  select coalesce(jsonb_agg(jsonb_build_object(
    'shopping_item_id', si.id,
    'title', si.title,
    'status', si.status,
    'purchase_method', si.purchase_method,
    'due_at', si.due_at,
    'assignment_mode', coalesce(si.assignment_mode,
      case when si.assignee_id is null then 'unassigned' else 'person' end),
    'assignee_actor_ref_id', si.assignee_actor_ref_id,
    'active_claimant_actor_ref_id', si.active_claimant_actor_ref_id,
    'duplicate_sensitivity', coalesce(si.duplicate_sensitivity, 'normal'),
    'revision', si.revision,
    'action_target', jsonb_build_object(
      'kind', 'shopping', 'shopping_item_id', si.id, 'revision', si.revision
    )
  ) order by si.due_at nulls last, si.created_at), '[]'::jsonb)
  into v_shopping
  from public.shopping_items si
  where si.household_id = v_household_id
    and si.test_context_id is null
    and si.status in ('wanted', 'assigned', 'ordered')
    and (
      si.assignee_id is null
      or si.assignee_id = p_actor_id
      or (v_actor_ref_id is not null and si.assignee_actor_ref_id = v_actor_ref_id)
      or (v_actor_ref_id is not null and si.active_claimant_actor_ref_id = v_actor_ref_id)
    );

  return jsonb_build_object(
    'generated_at', now(),
    'household_id', v_household_id,
    'local_date', v_date,
    'daypart', v_daypart,
    'urgent_actions', v_urgent_actions,
    'exceptions', v_exceptions,
    'active_infos', v_active_infos,
    'already_handled', v_already_handled,
    'burden_reducing_completed', v_already_handled,
    'own_task_groups', jsonb_build_object(
      'morning', v_morning,
      'daytime', v_daytime,
      'evening', v_evening
    ),
    'partner_summary', v_partner_summary,
    'carryovers', v_carryovers,
    'waiting_checks', v_waiting_checks,
    'reconciliation', v_reconciliation,
    'schedule', v_schedule,
    'shopping', v_shopping
  );
end;
$$;

revoke all on function public.server_read_daily_brief(uuid, date) from public, anon, authenticated;
grant execute on function public.server_read_daily_brief(uuid, date) to service_role;

-- Canonical detailed-design implementation, Batch 1A / R0 schema foundation.
-- No new semantic reader/writer is activated by this migration.
-- Existing production rows/writers continue to use legacy columns until a
-- separately reviewed aggregate cutover.

-- ---------------------------------------------------------------------------
-- ActorRef + test context
-- ---------------------------------------------------------------------------

create table public.test_simulation_contexts (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  operator_user_id uuid not null,
  label text null,
  status text not null default 'active' check (status in ('active', 'archived')),
  created_at timestamptz not null default now(),
  archived_at timestamptz null,
  unique (household_id, id),
  foreign key (household_id, operator_user_id)
    references public.household_members (household_id, user_id),
  check (
    (status = 'active' and archived_at is null)
    or (status = 'archived' and archived_at is not null)
  )
);

create index test_simulation_contexts_operator_idx
  on public.test_simulation_contexts (operator_user_id, status, created_at desc);

create table public.domain_actor_refs (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  actor_kind text not null check (actor_kind in ('real_user', 'simulated_member', 'system')),
  real_user_id uuid null,
  test_context_id uuid null,
  simulated_role text null check (simulated_role is null or simulated_role in ('papa', 'mama')),
  created_at timestamptz not null default now(),
  unique (household_id, id),
  foreign key (household_id, real_user_id)
    references public.household_members (household_id, user_id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id),
  check (
    (actor_kind = 'real_user' and real_user_id is not null and test_context_id is null and simulated_role is null)
    or (actor_kind = 'simulated_member' and real_user_id is null and test_context_id is not null and simulated_role is not null)
    or (actor_kind = 'system' and real_user_id is null and simulated_role is null)
  )
);

create unique index domain_actor_refs_real_user_idx
  on public.domain_actor_refs (household_id, real_user_id)
  where actor_kind = 'real_user';
create unique index domain_actor_refs_simulated_role_idx
  on public.domain_actor_refs (test_context_id, simulated_role)
  where actor_kind = 'simulated_member';

create or replace function private.fn_prevent_domain_actor_identity_rewrite()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.household_id is distinct from old.household_id
     or new.actor_kind is distinct from old.actor_kind
     or new.real_user_id is distinct from old.real_user_id
     or new.test_context_id is distinct from old.test_context_id
     or new.simulated_role is distinct from old.simulated_role then
    raise exception 'DOMAIN_ACTOR_IDENTITY_IMMUTABLE';
  end if;
  return new;
end;
$$;
revoke all on function private.fn_prevent_domain_actor_identity_rewrite() from public, anon, authenticated;
grant execute on function private.fn_prevent_domain_actor_identity_rewrite() to service_role;
create trigger prevent_domain_actor_identity_rewrite
  before update on public.domain_actor_refs
  for each row execute function private.fn_prevent_domain_actor_identity_rewrite();

-- ---------------------------------------------------------------------------
-- Existing Task/Request/Handover/Shopping aggregate evolution
-- ---------------------------------------------------------------------------

alter table public.task_definitions
  add column default_expectation text null
    check (default_expectation is null or default_expectation in ('required', 'normal', 'optional')),
  add column carryover_policy text null
    check (carryover_policy is null or carryover_policy in ('occurrence_ends', 'until_done', 'until_deadline', 'separate_next_occurrence')),
  add column duplicate_sensitivity text null
    check (duplicate_sensitivity is null or duplicate_sensitivity in ('normal', 'avoid_duplicate', 'safety_critical')),
  add column early_completion_policy text null
    check (early_completion_policy is null or early_completion_policy in ('none', 'recommended', 'required_before')),
  add column default_duration_minutes int null
    check (default_duration_minutes is null or default_duration_minutes between 1 and 1440);

alter table public.task_instances
  add column assignment_mode text null
    check (assignment_mode is null or assignment_mode in ('person', 'unassigned', 'anyone')),
  add column assignment_source text null,
  add column planned_assignee_actor_ref_id uuid null,
  add column active_claimant_actor_ref_id uuid null,
  add column claimed_at timestamptz null,
  add column expectation text null
    check (expectation is null or expectation in ('required', 'normal', 'optional')),
  add column carryover_policy text null
    check (carryover_policy is null or carryover_policy in ('occurrence_ends', 'until_done', 'until_deadline', 'separate_next_occurrence')),
  add column duplicate_sensitivity text null
    check (duplicate_sensitivity is null or duplicate_sensitivity in ('normal', 'avoid_duplicate', 'safety_critical')),
  add column early_completion_policy text null
    check (early_completion_policy is null or early_completion_policy in ('none', 'recommended', 'required_before')),
  add column available_from timestamptz null,
  add column attention_state text not null default 'active'
    check (attention_state in ('active', 'waiting')),
  add column waiting_note text null,
  add column next_check_at timestamptz null,
  add column outcome_reason text null
    check (outcome_reason is null or outcome_reason in ('could_not_do', 'not_needed_this_occurrence', 'expired_occurrence')),
  add column revision bigint not null default 1 check (revision >= 1),
  add column test_context_id uuid null,
  add column source_context jsonb not null default '{}'::jsonb,
  add foreign key (household_id, planned_assignee_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  add foreign key (household_id, active_claimant_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  add foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id),
  add check (
    assignment_mode is null
    or (assignment_mode = 'person' and planned_assignee_actor_ref_id is not null)
    or (assignment_mode in ('unassigned', 'anyone') and planned_assignee_actor_ref_id is null)
  ),
  add check (
    active_claimant_actor_ref_id is null
    or (assignment_mode = 'anyone' and status in ('todo', 'in_progress') and claimed_at is not null)
  ),
  add check (attention_state <> 'waiting' or status in ('todo', 'in_progress'));

create index task_instances_actor_assignment_idx
  on public.task_instances (household_id, planned_assignee_actor_ref_id, scheduled_date, status);
create index task_instances_claim_idx
  on public.task_instances (household_id, active_claimant_actor_ref_id, status)
  where active_claimant_actor_ref_id is not null;
create index task_instances_waiting_idx
  on public.task_instances (household_id, attention_state, next_check_at)
  where attention_state = 'waiting';
create index task_instances_test_context_idx
  on public.task_instances (test_context_id) where test_context_id is not null;

alter table public.task_events
  add column actor_ref_id uuid null,
  add column test_context_id uuid null,
  add foreign key (household_id, actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  add foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id);

-- requests lacked the redundant household/id unique key used by composite
-- household-scoped child FKs. Add it without changing the existing PK.
alter table public.requests
  add constraint requests_household_id_id_key unique (household_id, id),
  add column requester_actor_ref_id uuid null,
  add column recipient_actor_ref_id uuid null,
  add column request_kind text null
    check (request_kind is null or request_kind in ('light', 'assignment_change')),
  add column closed_at timestamptz null,
  add column revision bigint not null default 1 check (revision >= 1),
  add column test_context_id uuid null,
  add foreign key (household_id, requester_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  add foreign key (household_id, recipient_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  add foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id);

create index requests_actor_recipient_idx
  on public.requests (household_id, recipient_actor_ref_id, status, created_at desc);
create index requests_test_context_idx
  on public.requests (test_context_id) where test_context_id is not null;

alter table public.handovers
  add column author_actor_ref_id uuid null,
  add column test_context_id uuid null,
  add foreign key (household_id, author_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  add foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id);

alter table public.shopping_items
  add column assignment_mode text null
    check (assignment_mode is null or assignment_mode in ('person', 'unassigned', 'anyone')),
  add column assignee_actor_ref_id uuid null,
  add column active_claimant_actor_ref_id uuid null,
  add column claimed_at timestamptz null,
  add column duplicate_sensitivity text null
    check (duplicate_sensitivity is null or duplicate_sensitivity in ('normal', 'avoid_duplicate', 'safety_critical')),
  add column revision bigint not null default 1 check (revision >= 1),
  add column test_context_id uuid null,
  add foreign key (household_id, assignee_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  add foreign key (household_id, active_claimant_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  add foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id),
  add check (
    assignment_mode is null
    or (assignment_mode = 'person' and assignee_actor_ref_id is not null)
    or (assignment_mode in ('unassigned', 'anyone') and assignee_actor_ref_id is null)
  ),
  add check (
    active_claimant_actor_ref_id is null
    or (assignment_mode = 'anyone' and claimed_at is not null)
  );

alter table private.pending_actions
  add column actor_ref_id uuid null references public.domain_actor_refs (id),
  add column test_context_id uuid null references public.test_simulation_contexts (id);

alter table private.mutation_receipts
  add column actor_ref_id uuid null references public.domain_actor_refs (id),
  add column test_context_id uuid null references public.test_simulation_contexts (id);

-- ---------------------------------------------------------------------------
-- Canonical Task actual/reconciliation evidence
-- ---------------------------------------------------------------------------

create table public.task_actual_participants (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  task_instance_id uuid not null,
  actor_ref_id uuid not null,
  participation_kind text not null default 'performed' check (participation_kind = 'performed'),
  recorded_by_actor_ref_id uuid null,
  recorded_at timestamptz not null default now(),
  removed_at timestamptz null,
  removed_by_actor_ref_id uuid null,
  compatibility_primary boolean not null default false,
  source text not null default 'canonical' check (source in ('canonical', 'legacy_backfill')),
  test_context_id uuid null,
  created_at timestamptz not null default now(),
  unique (household_id, id),
  foreign key (household_id, task_instance_id)
    references public.task_instances (household_id, id),
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

create unique index task_actual_participants_active_actor_idx
  on public.task_actual_participants (task_instance_id, actor_ref_id)
  where removed_at is null;
create unique index task_actual_participants_compat_primary_idx
  on public.task_actual_participants (task_instance_id)
  where compatibility_primary and removed_at is null;

create table public.task_reconciliation_sessions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  actor_ref_id uuid not null,
  target_local_date date not null,
  group_key text not null,
  response_kind text not null check (response_kind in ('all_done', 'mostly_done', 'individual')),
  source text not null check (source in ('line', 'pwa')),
  test_context_id uuid null,
  supersedes_session_id uuid null,
  created_at timestamptz not null default now(),
  unique (household_id, id),
  foreign key (household_id, actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id),
  foreign key (household_id, supersedes_session_id)
    references public.task_reconciliation_sessions (household_id, id)
);

create index task_reconciliation_sessions_lookup_idx
  on public.task_reconciliation_sessions (household_id, target_local_date, group_key, created_at desc);

create table public.task_reconciliation_session_items (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  session_id uuid not null,
  task_instance_id uuid not null,
  observed_state text not null check (observed_state in ('completed', 'explicit_exception', 'unknown')),
  display_order int not null default 0,
  test_context_id uuid null,
  created_at timestamptz not null default now(),
  foreign key (household_id, session_id)
    references public.task_reconciliation_sessions (household_id, id),
  foreign key (household_id, task_instance_id)
    references public.task_instances (household_id, id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id),
  unique (session_id, task_instance_id)
);

-- ---------------------------------------------------------------------------
-- Canonical Request attempts / confirmations + ActorRef acknowledgement
-- ---------------------------------------------------------------------------

create table public.request_attempts (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  request_id uuid not null,
  attempt_kind text not null check (attempt_kind in ('initial', 'reproposal', 'change', 'cancel')),
  state text not null check (state in ('pending', 'checking', 'consulting', 'awaiting_confirmation', 'accepted', 'declined', 'expired', 'cancelled')),
  terms_revision int not null default 1 check (terms_revision >= 1),
  terms jsonb not null default '{}'::jsonb,
  reply_due_at timestamptz null,
  created_by_actor_ref_id uuid not null,
  accepted_at timestamptz null,
  declined_at timestamptz null,
  expired_at timestamptz null,
  cancelled_at timestamptz null,
  revision bigint not null default 1 check (revision >= 1),
  test_context_id uuid null,
  legacy_backfill boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, id),
  foreign key (household_id, request_id)
    references public.requests (household_id, id),
  foreign key (household_id, created_by_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id),
  check (
    (state = 'accepted' and accepted_at is not null and declined_at is null and expired_at is null and cancelled_at is null)
    or (state = 'declined' and declined_at is not null and accepted_at is null and expired_at is null and cancelled_at is null)
    or (state = 'expired' and expired_at is not null and accepted_at is null and declined_at is null and cancelled_at is null)
    or (state = 'cancelled' and cancelled_at is not null and accepted_at is null and declined_at is null and expired_at is null)
    or (state in ('pending', 'checking', 'consulting', 'awaiting_confirmation')
        and accepted_at is null and declined_at is null and expired_at is null and cancelled_at is null)
  )
);

create unique index request_attempts_one_legacy_backfill_idx
  on public.request_attempts (request_id) where legacy_backfill;
create unique index request_attempts_one_active_nonterminal_idx
  on public.request_attempts (request_id)
  where state in ('pending', 'checking', 'consulting', 'awaiting_confirmation');
create index request_attempts_request_created_idx
  on public.request_attempts (household_id, request_id, created_at desc);
create trigger set_updated_at
  before update on public.request_attempts
  for each row execute function public.set_updated_at();

create table public.request_attempt_confirmations (
  household_id uuid not null references public.households (id),
  attempt_id uuid not null,
  terms_revision int not null check (terms_revision >= 1),
  actor_ref_id uuid not null,
  confirmed_at timestamptz not null default now(),
  test_context_id uuid null,
  primary key (attempt_id, terms_revision, actor_ref_id),
  foreign key (household_id, attempt_id)
    references public.request_attempts (household_id, id),
  foreign key (household_id, actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id)
);

create table public.info_acknowledgements (
  household_id uuid not null references public.households (id),
  handover_id uuid not null,
  actor_ref_id uuid not null,
  acknowledged_at timestamptz not null default now(),
  test_context_id uuid null,
  primary key (handover_id, actor_ref_id),
  foreign key (household_id, handover_id)
    references public.handovers (household_id, id),
  foreign key (household_id, actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id)
);

-- ---------------------------------------------------------------------------
-- Actor/test-scope guards
-- ---------------------------------------------------------------------------

create or replace function private.fn_assert_actor_ref_scope(
  p_household_id uuid, p_actor_ref_id uuid, p_test_context_id uuid
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_kind text;
  v_actor_test_context_id uuid;
begin
  if p_actor_ref_id is null then return; end if;

  select actor_kind, test_context_id into v_kind, v_actor_test_context_id
  from public.domain_actor_refs
  where household_id = p_household_id and id = p_actor_ref_id;
  if not found then raise exception 'ACTOR_REF_NOT_IN_HOUSEHOLD'; end if;

  if p_test_context_id is null and v_kind = 'simulated_member' then
    raise exception 'SIMULATED_ACTOR_IN_PRODUCTION_ROW';
  end if;
  if p_test_context_id is not null and v_kind = 'simulated_member'
     and v_actor_test_context_id is distinct from p_test_context_id then
    raise exception 'SIMULATED_ACTOR_TEST_CONTEXT_MISMATCH';
  end if;
end;
$$;
revoke all on function private.fn_assert_actor_ref_scope(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function private.fn_assert_actor_ref_scope(uuid, uuid, uuid) to service_role;

create or replace function private.fn_enforce_existing_actor_scope()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_actor_column text;
  v_actor_ref_id uuid;
  v_test_context_id uuid;
begin
  v_test_context_id := nullif(to_jsonb(new)->>'test_context_id', '')::uuid;
  foreach v_actor_column in array tg_argv loop
    v_actor_ref_id := nullif(to_jsonb(new)->>v_actor_column, '')::uuid;
    perform private.fn_assert_actor_ref_scope(new.household_id, v_actor_ref_id, v_test_context_id);
  end loop;
  return new;
end;
$$;
revoke all on function private.fn_enforce_existing_actor_scope() from public, anon, authenticated;
grant execute on function private.fn_enforce_existing_actor_scope() to service_role;

create trigger task_instances_actor_scope_guard before insert or update of planned_assignee_actor_ref_id, active_claimant_actor_ref_id, test_context_id on public.task_instances
  for each row execute function private.fn_enforce_existing_actor_scope('planned_assignee_actor_ref_id', 'active_claimant_actor_ref_id');
create trigger task_events_actor_scope_guard before insert or update of actor_ref_id, test_context_id on public.task_events
  for each row execute function private.fn_enforce_existing_actor_scope('actor_ref_id');
create trigger requests_actor_scope_guard before insert or update of requester_actor_ref_id, recipient_actor_ref_id, test_context_id on public.requests
  for each row execute function private.fn_enforce_existing_actor_scope('requester_actor_ref_id', 'recipient_actor_ref_id');
create trigger handovers_actor_scope_guard before insert or update of author_actor_ref_id, test_context_id on public.handovers
  for each row execute function private.fn_enforce_existing_actor_scope('author_actor_ref_id');
create trigger shopping_items_actor_scope_guard before insert or update of assignee_actor_ref_id, active_claimant_actor_ref_id, test_context_id on public.shopping_items
  for each row execute function private.fn_enforce_existing_actor_scope('assignee_actor_ref_id', 'active_claimant_actor_ref_id');
create trigger task_actual_participants_actor_scope_guard before insert or update of actor_ref_id, recorded_by_actor_ref_id, removed_by_actor_ref_id, test_context_id on public.task_actual_participants
  for each row execute function private.fn_enforce_existing_actor_scope('actor_ref_id', 'recorded_by_actor_ref_id', 'removed_by_actor_ref_id');
create trigger task_reconciliation_sessions_actor_scope_guard before insert or update of actor_ref_id, test_context_id on public.task_reconciliation_sessions
  for each row execute function private.fn_enforce_existing_actor_scope('actor_ref_id');
create trigger request_attempts_actor_scope_guard before insert or update of created_by_actor_ref_id, test_context_id on public.request_attempts
  for each row execute function private.fn_enforce_existing_actor_scope('created_by_actor_ref_id');
create trigger request_attempt_confirmations_actor_scope_guard before insert or update of actor_ref_id, test_context_id on public.request_attempt_confirmations
  for each row execute function private.fn_enforce_existing_actor_scope('actor_ref_id');
create trigger info_acknowledgements_actor_scope_guard before insert or update of actor_ref_id, test_context_id on public.info_acknowledgements
  for each row execute function private.fn_enforce_existing_actor_scope('actor_ref_id');

create or replace function private.fn_enforce_canonical_child_test_context()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_parent_test_context_id uuid;
begin
  if tg_table_name in ('task_events', 'task_actual_participants') then
    select test_context_id into v_parent_test_context_id from public.task_instances
    where household_id = new.household_id and id = new.task_instance_id;
  elsif tg_table_name = 'request_attempts' then
    select test_context_id into v_parent_test_context_id from public.requests
    where household_id = new.household_id and id = new.request_id;
  elsif tg_table_name = 'request_attempt_confirmations' then
    select test_context_id into v_parent_test_context_id from public.request_attempts
    where household_id = new.household_id and id = new.attempt_id;
  elsif tg_table_name = 'info_acknowledgements' then
    select test_context_id into v_parent_test_context_id from public.handovers
    where household_id = new.household_id and id = new.handover_id;
  elsif tg_table_name = 'task_reconciliation_session_items' then
    select test_context_id into v_parent_test_context_id from public.task_reconciliation_sessions
    where household_id = new.household_id and id = new.session_id;
  else
    raise exception 'UNSUPPORTED_CHILD_SCOPE_TABLE';
  end if;

  if not found then raise exception 'CANONICAL_PARENT_NOT_FOUND'; end if;
  if new.test_context_id is distinct from v_parent_test_context_id then
    raise exception 'TEST_CONTEXT_PARENT_MISMATCH';
  end if;

  if tg_table_name = 'task_reconciliation_session_items' then
    select test_context_id into v_parent_test_context_id from public.task_instances
    where household_id = new.household_id and id = new.task_instance_id;
    if not found or new.test_context_id is distinct from v_parent_test_context_id then
      raise exception 'TEST_CONTEXT_TASK_MISMATCH';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.fn_enforce_canonical_child_test_context() from public, anon, authenticated;
grant execute on function private.fn_enforce_canonical_child_test_context() to service_role;

create trigger task_events_test_context_guard before insert or update of task_instance_id, test_context_id on public.task_events
  for each row execute function private.fn_enforce_canonical_child_test_context();
create trigger task_actual_participants_test_context_guard before insert or update of task_instance_id, test_context_id on public.task_actual_participants
  for each row execute function private.fn_enforce_canonical_child_test_context();
create trigger request_attempts_test_context_guard before insert or update of request_id, test_context_id on public.request_attempts
  for each row execute function private.fn_enforce_canonical_child_test_context();
create trigger request_attempt_confirmations_test_context_guard before insert or update of attempt_id, test_context_id on public.request_attempt_confirmations
  for each row execute function private.fn_enforce_canonical_child_test_context();
create trigger info_acknowledgements_test_context_guard before insert or update of handover_id, test_context_id on public.info_acknowledgements
  for each row execute function private.fn_enforce_canonical_child_test_context();
create trigger task_reconciliation_items_test_context_guard before insert or update of session_id, task_instance_id, test_context_id on public.task_reconciliation_session_items
  for each row execute function private.fn_enforce_canonical_child_test_context();

-- ---------------------------------------------------------------------------
-- CURRENT Task completion CHECK forward replacement
-- ---------------------------------------------------------------------------
-- Inline CHECK names are catalog-generated. Match actual definitions and abort
-- unless the expected CURRENT pair is found exactly once.
do $$
declare
  r record;
  v_subtask_name text;
  v_whole_name text;
  v_subtask_count int := 0;
  v_whole_count int := 0;
  v_def text;
begin
  for r in
    select c.conname, pg_get_constraintdef(c.oid) as def
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public' and t.relname = 'task_instances' and c.contype = 'c'
  loop
    v_def := lower(r.def);
    if v_def like '%completion_mode%subtasks%actual_completed_by_id%is null%'
       and v_def not like '%whole%' then
      v_subtask_name := r.conname;
      v_subtask_count := v_subtask_count + 1;
    elsif v_def like '%completion_mode%whole%status%completed%actual_completed_by_id%is not null%' then
      v_whole_name := r.conname;
      v_whole_count := v_whole_count + 1;
    end if;
  end loop;

  if v_subtask_count <> 1 or v_whole_count <> 1 then
    raise exception 'CURRENT_TASK_COMPLETION_CHECK_DRIFT subtask=% whole=%', v_subtask_count, v_whole_count;
  end if;
  execute format('alter table public.task_instances drop constraint %I', v_subtask_name);
  execute format('alter table public.task_instances drop constraint %I', v_whole_name);
end;
$$;

alter table public.task_instances
  add constraint task_instances_subtasks_legacy_actor_null_v2
    check (completion_mode <> 'subtasks' or actual_completed_by_id is null),
  add constraint task_instances_whole_completion_legacy_actor_v2
    check (
      not (completion_mode = 'whole' and status = 'completed')
      or test_context_id is not null
      or actual_completed_by_id is not null
    );

-- ---------------------------------------------------------------------------
-- RLS/direct-read boundary
-- ---------------------------------------------------------------------------

alter table public.test_simulation_contexts enable row level security;
grant select on public.test_simulation_contexts to authenticated;
create policy test_simulation_contexts_select on public.test_simulation_contexts
  for select to authenticated
  using (operator_user_id = auth.uid() and public.is_household_member(household_id));

alter table public.domain_actor_refs enable row level security;
grant select on public.domain_actor_refs to authenticated;
create policy domain_actor_refs_select on public.domain_actor_refs
  for select to authenticated
  using (public.is_household_member(household_id) and actor_kind <> 'simulated_member');

-- Existing direct production readers exclude future test rows. The test UX will
-- use a dedicated server path in WP-DD3A rather than reusing production reads.
drop policy if exists task_instances_select on public.task_instances;
create policy task_instances_select on public.task_instances
  for select to authenticated using (public.is_household_member(household_id) and test_context_id is null);
drop policy if exists task_events_select on public.task_events;
create policy task_events_select on public.task_events
  for select to authenticated using (public.is_household_member(household_id) and test_context_id is null);
drop policy if exists requests_select on public.requests;
create policy requests_select on public.requests
  for select to authenticated using (public.is_household_member(household_id) and test_context_id is null);
drop policy if exists handovers_select on public.handovers;
create policy handovers_select on public.handovers
  for select to authenticated using (public.is_household_member(household_id) and test_context_id is null);
drop policy if exists shopping_items_select on public.shopping_items;
create policy shopping_items_select on public.shopping_items
  for select to authenticated using (public.is_household_member(household_id) and test_context_id is null);

do $$
declare
  t text;
  tables text[] := array[
    'task_actual_participants',
    'task_reconciliation_sessions',
    'task_reconciliation_session_items',
    'request_attempts',
    'request_attempt_confirmations',
    'info_acknowledgements'
  ];
begin
  foreach t in array tables loop
    execute format('alter table public.%I enable row level security', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.is_household_member(household_id) and test_context_id is null)',
      t || '_select', t
    );
  end loop;
end;
$$;

-- No legacy NOT NULL identity column is relaxed in Batch 1A. Simulated writes
-- therefore remain impossible through current runtime, which is intentional:
-- WP-DD3A will relax only the required compatibility columns after backfill and
-- reconciliation are reviewed/clean.

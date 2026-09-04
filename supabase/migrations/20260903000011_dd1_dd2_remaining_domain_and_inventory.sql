-- WP-DD1 / WP-DD2 remaining additive foundation.
--
-- Everything in this migration is R0 readiness: new canonical tables are empty,
-- external Family Event writer ownership defaults disabled, provider inventory is
-- read-only, and no current reader/writer/capability gate is switched.

-- ---------------------------------------------------------------------------
-- Task subtask ActorRef/test compatibility
-- ---------------------------------------------------------------------------

alter table public.task_subtask_instances
  add column completed_by_actor_ref_id uuid null,
  add column recorded_by_actor_ref_id uuid null,
  add column test_context_id uuid null,
  add foreign key (household_id, completed_by_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  add foreign key (household_id, recorded_by_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  add foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id);

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
      and t.relname = 'task_subtask_instances'
      and c.contype = 'c'
  loop
    v_def := lower(r.def);
    if v_def like '%is_completed%'
       and v_def like '%completed_by%'
       and v_def like '%completed_at%' then
      v_name := r.conname;
      v_count := v_count + 1;
    end if;
  end loop;

  if v_count <> 1 then
    raise exception 'CURRENT_SUBTASK_COMPLETION_CHECK_DRIFT count=%', v_count;
  end if;
  execute format('alter table public.task_subtask_instances drop constraint %I', v_name);
end;
$$;

alter table public.task_subtask_instances
  add constraint task_subtask_instances_completion_v2_chk
  check (
    (is_completed
      and completed_at is not null
      and (completed_by is not null or completed_by_actor_ref_id is not null))
    or
    (not is_completed
      and completed_by is null
      and completed_by_actor_ref_id is null
      and completed_at is null)
  ),
  add constraint task_subtask_instances_test_legacy_actor_null_v2_chk
  check (test_context_id is null or completed_by is null);

create index task_subtask_instances_test_context_idx
  on public.task_subtask_instances (test_context_id)
  where test_context_id is not null;

create trigger task_subtask_instances_actor_scope_guard_v2
  before insert or update of completed_by_actor_ref_id, recorded_by_actor_ref_id, test_context_id
  on public.task_subtask_instances
  for each row execute function private.fn_enforce_existing_actor_scope(
    'completed_by_actor_ref_id', 'recorded_by_actor_ref_id'
  );

-- ---------------------------------------------------------------------------
-- Shopping participant foundation
-- ---------------------------------------------------------------------------

create table public.shopping_actual_participants (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  shopping_item_id uuid not null,
  actor_ref_id uuid not null,
  recorded_by_actor_ref_id uuid not null,
  source text not null default 'canonical',
  removed_at timestamptz null,
  removed_by_actor_ref_id uuid null,
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
    references public.test_simulation_contexts (household_id, id)
);

create unique index shopping_actual_participants_active_idx
  on public.shopping_actual_participants (shopping_item_id, actor_ref_id)
  where removed_at is null;
create index shopping_actual_participants_test_context_idx
  on public.shopping_actual_participants (test_context_id)
  where test_context_id is not null;

create trigger shopping_actual_participants_scope_guard_v1
  before insert or update of actor_ref_id, recorded_by_actor_ref_id, removed_by_actor_ref_id, test_context_id
  on public.shopping_actual_participants
  for each row execute function private.fn_enforce_existing_actor_scope(
    'actor_ref_id', 'recorded_by_actor_ref_id', 'removed_by_actor_ref_id'
  );

-- ---------------------------------------------------------------------------
-- Family Event + field authority + provider-link foundation
-- ---------------------------------------------------------------------------

create table public.family_events (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  title text not null check (length(btrim(title)) between 1 and 240),
  status text not null default 'active'
    check (status in ('active', 'waiting_reschedule', 'cancelled')),
  all_day boolean not null default false,
  starts_at timestamptz null,
  ends_at timestamptz null,
  starts_on date null,
  ends_on date null,
  location_text text null,
  details text null,
  calendar_sync_preference text not null default 'none'
    check (calendar_sync_preference in ('none', 'family_ops_owned', 'external_follow')),
  revision bigint not null default 1 check (revision >= 1),
  created_by_actor_ref_id uuid not null,
  test_context_id uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, id),
  foreign key (household_id, created_by_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id),
  check (
    (all_day
      and starts_on is not null and ends_on is not null
      and starts_at is null and ends_at is null
      and ends_on >= starts_on)
    or
    (not all_day
      and starts_at is not null and ends_at is not null
      and starts_on is null and ends_on is null
      and ends_at >= starts_at)
  )
);

create index family_events_household_timed_idx
  on public.family_events (household_id, starts_at, ends_at)
  where not all_day and status <> 'cancelled';
create index family_events_household_all_day_idx
  on public.family_events (household_id, starts_on, ends_on)
  where all_day and status <> 'cancelled';
create index family_events_test_context_idx
  on public.family_events (test_context_id) where test_context_id is not null;
create trigger set_updated_at
  before update on public.family_events
  for each row execute function public.set_updated_at();
create trigger family_events_actor_scope_guard_v1
  before insert or update of created_by_actor_ref_id, test_context_id
  on public.family_events
  for each row execute function private.fn_enforce_existing_actor_scope('created_by_actor_ref_id');

create table public.family_event_field_authorities (
  household_id uuid not null references public.households (id),
  family_event_id uuid not null,
  field_name text not null check (field_name in ('title', 'schedule', 'location')),
  authority_mode text not null check (authority_mode in ('human_protected', 'external_follow')),
  revision bigint not null default 1 check (revision >= 1),
  test_context_id uuid null,
  updated_at timestamptz not null default now(),
  primary key (family_event_id, field_name),
  foreign key (household_id, family_event_id)
    references public.family_events (household_id, id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id)
);
create trigger set_updated_at
  before update on public.family_event_field_authorities
  for each row execute function public.set_updated_at();

create table public.family_event_external_links (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  family_event_id uuid not null,
  provider text not null default 'google' check (provider = 'google'),
  calendar_connection_id uuid not null,
  google_event_id text not null check (length(btrim(google_event_id)) > 0),
  link_mode text not null check (link_mode in ('family_ops_owned', 'external_follow')),
  last_external_owned_field_snapshot jsonb not null default '{}'::jsonb,
  last_external_etag text null,
  last_reconciled_at timestamptz null,
  provider_identity_revalidated_at timestamptz null,
  writer_enabled boolean not null default false,
  ownership_transfer_state text not null default 'inactive'
    check (ownership_transfer_state in ('inactive', 'validated', 'active', 'blocked')),
  test_context_id uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, id),
  unique (calendar_connection_id, google_event_id),
  foreign key (household_id, family_event_id)
    references public.family_events (household_id, id),
  foreign key (calendar_connection_id)
    references public.calendar_connections (id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id),
  check (not writer_enabled or (test_context_id is null and ownership_transfer_state = 'active'))
);
create index family_event_external_links_event_idx
  on public.family_event_external_links (household_id, family_event_id);
create trigger set_updated_at
  before update on public.family_event_external_links
  for each row execute function public.set_updated_at();

-- Existing provider paths get explicit, non-activating ownership-transfer state.
alter table private.family_ops_calendar_mirrors
  add column ownership_transfer_state text not null default 'task_owned'
    check (ownership_transfer_state in ('task_owned', 'transfer_pending', 'transferred')),
  add column ownership_transfer_block_reason text null;

alter table private.family_ops_calendar_target_deletions
  add column ownership_transfer_state text not null default 'delete_owned'
    check (ownership_transfer_state in ('delete_owned', 'superseded', 'blocked_by_transfer')),
  add column ownership_transfer_block_reason text null;

alter table private.family_ops_calendar_orphaned_mirrors
  add column provider_identity_revalidated_at timestamptz null,
  add column provider_revalidated_etag text null,
  add column adoption_blocked boolean not null default true;

-- No Family Event provider writer can be activated while the same stable
-- provider identity still belongs to either existing mutation path, or while a
-- matching orphan has not been freshly revalidated. This is representation and
-- guard only: this PR contains no ownership-transfer command/provider worker.
create or replace function private.fn_guard_family_event_provider_writer_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not new.writer_enabled then return new; end if;
  if new.test_context_id is not null then raise exception 'TEST_SIDE_EFFECT_FORBIDDEN'; end if;
  if new.provider_identity_revalidated_at is null then
    raise exception 'FAMILY_EVENT_PROVIDER_IDENTITY_NOT_REVALIDATED';
  end if;

  if exists (
    select 1 from private.family_ops_calendar_mirrors m
    where m.calendar_connection_id = new.calendar_connection_id
      and m.provider_event_id = new.google_event_id
      and m.ownership_transfer_state <> 'transferred'
      and m.sync_state <> 'deleted'
  ) then
    raise exception 'FAMILY_EVENT_PROVIDER_OWNER_CONFLICT_TASK_MIRROR';
  end if;

  if exists (
    select 1 from private.family_ops_calendar_target_deletions d
    where (to_jsonb(d)->>'calendar_connection_id')::uuid = new.calendar_connection_id
      and to_jsonb(d)->>'provider_event_id' = new.google_event_id
      and coalesce(to_jsonb(d)->>'ownership_transfer_state', 'delete_owned') = 'delete_owned'
      and coalesce(to_jsonb(d)->>'sync_state', '') <> 'deleted'
  ) then
    raise exception 'FAMILY_EVENT_PROVIDER_OWNER_CONFLICT_TARGET_DELETE';
  end if;

  if exists (
    select 1 from private.family_ops_calendar_orphaned_mirrors o
    where o.calendar_connection_id = new.calendar_connection_id
      and o.provider_event_id = new.google_event_id
      and (o.adoption_blocked or o.provider_identity_revalidated_at is null)
  ) then
    raise exception 'FAMILY_EVENT_PROVIDER_ORPHAN_REVALIDATION_REQUIRED';
  end if;
  return new;
end;
$$;
revoke all on function private.fn_guard_family_event_provider_writer_v1()
  from public, anon, authenticated;
grant execute on function private.fn_guard_family_event_provider_writer_v1() to service_role;
create trigger family_event_external_links_writer_guard_v1
  before insert or update of writer_enabled, ownership_transfer_state,
    provider_identity_revalidated_at, calendar_connection_id, google_event_id, test_context_id
  on public.family_event_external_links
  for each row execute function private.fn_guard_family_event_provider_writer_v1();

alter table public.task_instances
  add column event_id uuid null,
  add foreign key (household_id, event_id)
    references public.family_events (household_id, id);
create index task_instances_event_idx
  on public.task_instances (household_id, event_id) where event_id is not null;

alter table public.handovers
  add column related_event_id uuid null,
  add foreign key (household_id, related_event_id)
    references public.family_events (household_id, id);

-- ---------------------------------------------------------------------------
-- Generic change-candidate foundation
-- ---------------------------------------------------------------------------

create table public.change_candidates (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  target_type text not null check (target_type in ('family_event', 'task', 'recurrence', 'info')),
  target_id uuid null,
  source_type text not null check (source_type in ('google', 'image_fact', 'ai_inference', 'manual_import')),
  source_ref text null,
  proposed_patch jsonb not null,
  current_snapshot_hash text null,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'rejected', 'superseded', 'stale')),
  resolved_at timestamptz null,
  resolved_by_actor_ref_id uuid null,
  revision bigint not null default 1 check (revision >= 1),
  test_context_id uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (household_id, resolved_by_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id),
  check (
    (status = 'pending' and resolved_at is null and resolved_by_actor_ref_id is null)
    or (status <> 'pending' and resolved_at is not null and resolved_by_actor_ref_id is not null)
  )
);
create index change_candidates_target_idx
  on public.change_candidates (household_id, target_type, target_id, status, created_at desc);
create index change_candidates_source_idx
  on public.change_candidates (household_id, source_type, source_ref, status);
create index change_candidates_test_context_idx
  on public.change_candidates (test_context_id) where test_context_id is not null;
create trigger set_updated_at
  before update on public.change_candidates
  for each row execute function public.set_updated_at();
create trigger change_candidates_actor_scope_guard_v1
  before insert or update of resolved_by_actor_ref_id, test_context_id
  on public.change_candidates
  for each row execute function private.fn_enforce_existing_actor_scope('resolved_by_actor_ref_id');

-- ---------------------------------------------------------------------------
-- Children / school / source-document foundation
-- ---------------------------------------------------------------------------

create table public.family_children (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  display_name text not null check (length(btrim(display_name)) between 1 and 120),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, id)
);
create trigger set_updated_at before update on public.family_children
  for each row execute function public.set_updated_at();

create table public.child_school_contexts (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  child_id uuid not null,
  school_display_name text not null,
  class_display_name text null,
  effective_from date not null,
  effective_to date null,
  recognition_aliases text[] not null default '{}',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, id),
  foreign key (household_id, child_id)
    references public.family_children (household_id, id),
  check (effective_to is null or effective_to >= effective_from)
);
create index child_school_contexts_child_active_idx
  on public.child_school_contexts (household_id, child_id, active, effective_from desc);
create trigger set_updated_at before update on public.child_school_contexts
  for each row execute function public.set_updated_at();

create table private.source_documents (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  uploaded_by_actor_ref_id uuid not null,
  document_kind text not null,
  storage_object_key text not null,
  captured_at timestamptz null,
  uploaded_at timestamptz not null default now(),
  raw_deleted_at timestamptz null,
  retention_policy text not null default 'short_lived',
  test_context_id uuid null,
  foreign key (household_id, uploaded_by_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id)
);
revoke all on private.source_documents from public, anon, authenticated;
grant select, insert, update, delete on private.source_documents to service_role;

create table private.document_extractions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  source_document_id uuid not null references private.source_documents (id),
  extraction_version text not null,
  provider_metadata jsonb not null default '{}'::jsonb,
  school_context_candidate jsonb null,
  state text not null default 'processing'
    check (state in ('processing', 'review', 'confirmed', 'rejected', 'failed')),
  test_context_id uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id)
);
revoke all on private.document_extractions from public, anon, authenticated;
grant select, insert, update, delete on private.document_extractions to service_role;
create trigger set_updated_at before update on private.document_extractions
  for each row execute function public.set_updated_at();

create table private.document_facts (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  extraction_id uuid not null references private.document_extractions (id),
  child_school_context_id uuid null,
  fact_kind text not null check (fact_kind in ('event', 'required_item', 'deadline', 'recurrence', 'url', 'note')),
  normalized_value jsonb not null,
  confidence_band text not null check (confidence_band in ('high', 'medium', 'low')),
  source_locator text null,
  fact_origin text not null default 'source_explicit' check (fact_origin = 'source_explicit'),
  test_context_id uuid null,
  created_at timestamptz not null default now(),
  foreign key (household_id, child_school_context_id)
    references public.child_school_contexts (household_id, id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id)
);
revoke all on private.document_facts from public, anon, authenticated;
grant select, insert, update, delete on private.document_facts to service_role;

create table public.school_preparation_rules (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  child_school_context_id uuid not null,
  trigger_spec jsonb not null,
  preparation_template jsonb not null,
  confirmed_by_actor_ref_id uuid not null,
  effective_from date not null,
  effective_to date null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (household_id, child_school_context_id)
    references public.child_school_contexts (household_id, id),
  foreign key (household_id, confirmed_by_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  check (effective_to is null or effective_to >= effective_from)
);
create trigger set_updated_at before update on public.school_preparation_rules
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS: ordinary authenticated reads never see test-scoped canonical rows.
-- New schemas remain read-only to browser roles until later aggregate cutover.
-- ---------------------------------------------------------------------------

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'shopping_actual_participants',
    'family_events',
    'family_event_field_authorities',
    'family_event_external_links',
    'change_candidates',
    'family_children',
    'child_school_contexts',
    'school_preparation_rules'
  ] loop
    execute format('alter table public.%I enable row level security', v_table);
    execute format('grant select on public.%I to authenticated', v_table);
  end loop;
end;
$$;

create policy shopping_actual_participants_production_select
  on public.shopping_actual_participants for select to authenticated
  using (test_context_id is null and public.is_household_member(household_id));
create policy family_events_production_select
  on public.family_events for select to authenticated
  using (test_context_id is null and public.is_household_member(household_id));
create policy family_event_field_authorities_production_select
  on public.family_event_field_authorities for select to authenticated
  using (test_context_id is null and public.is_household_member(household_id));
create policy family_event_external_links_production_select
  on public.family_event_external_links for select to authenticated
  using (test_context_id is null and public.is_household_member(household_id));
create policy change_candidates_production_select
  on public.change_candidates for select to authenticated
  using (test_context_id is null and public.is_household_member(household_id));
create policy family_children_select
  on public.family_children for select to authenticated
  using (public.is_household_member(household_id));
create policy child_school_contexts_select
  on public.child_school_contexts for select to authenticated
  using (public.is_household_member(household_id));
create policy school_preparation_rules_select
  on public.school_preparation_rules for select to authenticated
  using (public.is_household_member(household_id));

grant select, insert, update, delete on public.shopping_actual_participants to service_role;
grant select, insert, update, delete on public.family_events to service_role;
grant select, insert, update, delete on public.family_event_field_authorities to service_role;
grant select, insert, update, delete on public.family_event_external_links to service_role;
grant select, insert, update, delete on public.change_candidates to service_role;
grant select, insert, update, delete on public.family_children to service_role;
grant select, insert, update, delete on public.child_school_contexts to service_role;
grant select, insert, update, delete on public.school_preparation_rules to service_role;

-- ---------------------------------------------------------------------------
-- WP-DD2 baseline CURRENT-main 50-table assertion + provider lifecycle inventory
-- ---------------------------------------------------------------------------

create or replace function private.canonical_current_main_table_inventory_v1()
returns table(schema_name text, table_name text, disposition text, present boolean)
language sql stable security definer set search_path = '' as $$
  with expected(schema_name, table_name, disposition) as (
    values
      ('public','households','KEEP'), ('public','profiles','KEEP'),
      ('public','household_members','KEEP'), ('public','household_task_categories','EVOLVE'),
      ('public','task_definitions','EVOLVE'), ('public','task_subtask_definitions','KEEP'),
      ('public','recurrence_rules','EVOLVE'), ('public','task_instances','EVOLVE'),
      ('public','task_subtask_instances','EVOLVE'), ('public','task_events','EVOLVE'),
      ('public','requests','EVOLVE'), ('public','handovers','EVOLVE'),
      ('public','handover_reads','EVOLVE'), ('public','shopping_items','EVOLVE'),
      ('public','user_notifications','EVOLVE'), ('public','notification_preferences','EVOLVE'),
      ('public','household_routine_schedules','EVOLVE'), ('public','routine_checkin_sessions','SUPERSEDE'),
      ('public','routine_checkin_session_items','SUPERSEDE'), ('public','evening_routine_preferences','EVOLVE'),
      ('public','calendar_connections','KEEP'), ('public','calendar_events_cache','KEEP'),
      ('public','calendar_event_occurrences','KEEP'), ('public','calendar_occurrence_busy_members','KEEP'),
      ('public','calendar_busy_classifications','KEEP'), ('public','calendar_busy_classification_members','KEEP'),
      ('public','assignment_change_request_tasks','SUPERSEDE'),
      ('private','google_connections','KEEP'), ('private','google_watch_channels','KEEP'),
      ('private','google_sync_state','KEEP'), ('private','google_sync_jobs','KEEP'),
      ('private','google_event_staging','KEEP'), ('private','google_write_operations','KEEP'),
      ('private','family_ops_calendar_mirrors','BRIDGE'), ('private','family_ops_calendar_target_deletions','BRIDGE'),
      ('private','family_ops_calendar_orphaned_mirrors','KEEP'), ('private','webhook_inbox','KEEP'),
      ('private','line_user_links','KEEP'), ('private','pending_actions','EVOLVE'),
      ('private','raw_inputs','EVOLVE'), ('private','household_invites','OUT-OF-SCOPE'),
      ('private','line_link_tokens','OUT-OF-SCOPE'), ('private','google_oauth_states','KEEP'),
      ('private','notification_outbox','EVOLVE'), ('private','line_quota_state','KEEP'),
      ('private','line_quota_reservations','KEEP'), ('private','worker_run_receipts','KEEP'),
      ('private','jp_holidays','KEEP'), ('private','mutation_receipts','EVOLVE'),
      ('private','scheduled_dispatch_receipts','EVOLVE')
  )
  select e.schema_name, e.table_name, e.disposition,
    to_regclass(format('%I.%I', e.schema_name, e.table_name)) is not null
  from expected e
  order by e.schema_name, e.table_name;
$$;
revoke all on function private.canonical_current_main_table_inventory_v1()
  from public, anon, authenticated;
grant execute on function private.canonical_current_main_table_inventory_v1() to service_role;

create or replace function private.canonical_google_provider_lifecycle_inventory_v1()
returns table(
  subsystem text,
  household_id uuid,
  provider_identity text,
  provider_mutation_active boolean,
  snapshot jsonb
)
language sql stable security definer set search_path = '' as $$
  select
    'task_mirror'::text,
    m.household_id,
    m.calendar_connection_id::text || ':' || coalesce(m.provider_event_id, '<pending>') || ':' || m.projection_key,
    m.sync_state not in ('deleted', 'blocked') and m.ownership_transfer_state <> 'transferred',
    to_jsonb(m)
  from private.family_ops_calendar_mirrors m

  union all

  select
    'target_deletion'::text,
    (to_jsonb(d)->>'household_id')::uuid,
    coalesce(to_jsonb(d)->>'calendar_connection_id', '') || ':'
      || coalesce(to_jsonb(d)->>'provider_event_id', '<unknown>') || ':'
      || coalesce(to_jsonb(d)->>'projection_key', '<unknown>'),
    coalesce(to_jsonb(d)->>'sync_state', '') not in ('deleted', 'blocked')
      and coalesce(to_jsonb(d)->>'ownership_transfer_state', 'delete_owned') = 'delete_owned',
    to_jsonb(d)
  from private.family_ops_calendar_target_deletions d

  union all

  select
    'orphan_observation'::text,
    o.household_id,
    o.calendar_connection_id::text || ':' || o.provider_event_id || ':' || o.projection_key,
    false,
    to_jsonb(o)
  from private.family_ops_calendar_orphaned_mirrors o;
$$;
revoke all on function private.canonical_google_provider_lifecycle_inventory_v1()
  from public, anon, authenticated;
grant execute on function private.canonical_google_provider_lifecycle_inventory_v1() to service_role;

-- Extend the existing reconciliation with the baseline physical precondition and
-- Request/Task/assignment-scope anomaly classes required before any cutover.
alter function private.canonical_foundation_reconciliation_v1()
  rename to canonical_foundation_reconciliation_v1_pre_dd1b;

create or replace function private.canonical_foundation_reconciliation_v1()
returns table(issue_type text, issue_count bigint)
language sql stable security definer set search_path = '' as $$
  select * from private.canonical_foundation_reconciliation_v1_pre_dd1b()

  union all
  select 'current_main_baseline_table_missing'::text, count(*)
  from private.canonical_current_main_table_inventory_v1() i
  where not i.present

  union all
  select 'request_accepted_or_completed_missing_linked_task'::text, count(*)
  from public.requests r
  where r.test_context_id is null
    and r.status in ('accepted', 'completed')
    and r.linked_task_instance_id is null

  union all
  select 'request_linked_task_wrong_household_or_missing'::text, count(*)
  from public.requests r
  where r.test_context_id is null
    and r.linked_task_instance_id is not null
    and not exists (
      select 1 from public.task_instances t
      where t.household_id = r.household_id and t.id = r.linked_task_instance_id
    )

  union all
  select 'legacy_completed_request_task_not_completed'::text, count(*)
  from public.requests r
  join public.task_instances t
    on t.household_id = r.household_id and t.id = r.linked_task_instance_id
  where r.test_context_id is null
    and r.status = 'completed'
    and t.status <> 'completed'

  union all
  select 'accepted_request_task_contradictory_terminal'::text, count(*)
  from public.requests r
  join public.task_instances t
    on t.household_id = r.household_id and t.id = r.linked_task_instance_id
  where r.test_context_id is null
    and r.status = 'accepted'
    and t.status in ('skipped', 'cancelled')

  union all
  select 'assignment_change_scope_duplicate_or_invalid'::text, count(*)
  from (
    select a.request_id, a.task_instance_id
    from public.assignment_change_request_tasks a
    left join public.requests r on r.id = a.request_id and r.household_id = a.household_id
    left join public.task_instances t on t.id = a.task_instance_id and t.household_id = a.household_id
    where r.id is null or t.id is null
  ) x

  union all
  select 'request_legacy_lifecycle_timestamp_contradiction'::text, count(*)
  from public.requests r
  where r.test_context_id is null and not (
    (r.status = 'pending' and r.accepted_at is null and r.declined_at is null and r.cancelled_at is null and r.completed_at is null)
    or (r.status = 'accepted' and r.accepted_at is not null and r.declined_at is null and r.cancelled_at is null and r.completed_at is null)
    or (r.status = 'declined' and r.declined_at is not null and r.accepted_at is null and r.cancelled_at is null and r.completed_at is null)
    or (r.status = 'cancelled' and r.cancelled_at is not null and r.accepted_at is null and r.declined_at is null and r.completed_at is null)
    or (r.status = 'completed' and r.accepted_at is not null and r.completed_at is not null and r.declined_at is null and r.cancelled_at is null)
  );
$$;
revoke all on function private.canonical_foundation_reconciliation_v1()
  from public, anon, authenticated;
grant execute on function private.canonical_foundation_reconciliation_v1() to service_role;

-- Baseline declaration itself must stay exactly 50 rows (27 public + 23 private).
do $$
declare
  v_total int;
  v_public int;
  v_private int;
  v_missing int;
begin
  select count(*), count(*) filter (where schema_name = 'public'),
         count(*) filter (where schema_name = 'private'),
         count(*) filter (where not present)
    into v_total, v_public, v_private, v_missing
  from private.canonical_current_main_table_inventory_v1();

  if v_total <> 50 or v_public <> 27 or v_private <> 23 then
    raise exception 'CURRENT_MAIN_INVENTORY_DECLARATION_DRIFT total=% public=% private=%',
      v_total, v_public, v_private;
  end if;
  if v_missing <> 0 then
    raise exception 'CURRENT_MAIN_PHYSICAL_PRECONDITION_MISSING count=%', v_missing;
  end if;
end;
$$;

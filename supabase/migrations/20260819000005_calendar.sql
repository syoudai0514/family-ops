-- WP1: Google Calendar connection / canonical cache / occurrence projection /
-- busy classification / private sync-and-write state
-- docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #9-#13,#18; 15_DDL_CONTRACT.md #12-14,21

-- ---------------------------------------------------------------------------
-- Connection (credential lives in private schema; household-bound handle in public)
-- ---------------------------------------------------------------------------

create table private.google_connections (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  owner_user_id uuid not null,
  google_subject text not null,
  encrypted_refresh_token text not null,
  encryption_version int not null,
  scopes text[] not null,
  status text not null check (status in ('active', 'reauth_required', 'revoked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, id),
  foreign key (household_id, owner_user_id)
    references public.household_members (household_id, user_id)
);

create trigger set_updated_at
  before update on private.google_connections
  for each row execute function public.set_updated_at();

create table public.calendar_connections (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  provider text not null default 'google',
  external_calendar_id text not null,
  display_name text null,
  google_connection_id uuid not null,
  active boolean not null default true,
  last_incremental_sync_at timestamptz null,
  last_occurrence_projection_at timestamptz null,
  reauth_required boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, external_calendar_id),
  unique (household_id, id),
  foreign key (household_id, google_connection_id)
    references private.google_connections (household_id, id)
);

create trigger set_updated_at
  before update on public.calendar_connections
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Canonical event cache (nullable-heavy: must accept deleted/cancelled/untitled)
-- ---------------------------------------------------------------------------

create table public.calendar_events_cache (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  calendar_connection_id uuid not null,
  google_event_id text not null,
  recurring_event_id text null,
  original_start_time jsonb null,
  title text null,
  description text null,
  location text null,
  starts_at timestamptz null,
  ends_at timestamptz null,
  all_day_start date null,
  all_day_end_exclusive date null,
  status text not null,
  recurrence jsonb null,
  creator_external_id text null,
  creator_mapped_user_id uuid null,
  organizer_external_id text null,
  transparency text null,
  google_updated_at timestamptz null,
  etag text null,
  raw_version_hash text null,
  tombstone_kind text null check (tombstone_kind is null or tombstone_kind in ('deleted', 'cancelled_exception')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (calendar_connection_id, google_event_id),
  foreign key (household_id, calendar_connection_id)
    references public.calendar_connections (household_id, id),
  foreign key (household_id, creator_mapped_user_id)
    references public.household_members (household_id, user_id)
);

create index calendar_events_cache_hh_conn_updated_idx
  on public.calendar_events_cache (household_id, calendar_connection_id, google_updated_at);

create trigger set_updated_at
  before update on public.calendar_events_cache
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Occurrence projection (Google-expanded instances only; no local RRULE parser)
-- ---------------------------------------------------------------------------

create table public.calendar_event_occurrences (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  calendar_connection_id uuid not null,
  occurrence_key text not null,
  google_event_id text not null,
  recurring_event_id text null,
  title text null,
  starts_at timestamptz null,
  ends_at timestamptz null,
  all_day_start date null,
  all_day_end_exclusive date null,
  status text not null,
  creator_mapped_user_id uuid null,
  transparency text null,
  projection_window_start date not null,
  projection_window_end date not null,
  source_google_updated_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (calendar_connection_id, occurrence_key),
  unique (household_id, calendar_connection_id, occurrence_key),
  foreign key (household_id, calendar_connection_id)
    references public.calendar_connections (household_id, id),
  foreign key (household_id, creator_mapped_user_id)
    references public.household_members (household_id, user_id)
);

create index calendar_event_occurrences_starts_at_idx
  on public.calendar_event_occurrences (household_id, starts_at);

create trigger set_updated_at
  before update on public.calendar_event_occurrences
  for each row execute function public.set_updated_at();

create table public.calendar_occurrence_busy_members (
  household_id uuid not null references public.households (id),
  calendar_connection_id uuid not null,
  occurrence_key text not null,
  user_id uuid not null,
  source text not null check (source in ('family_ops_metadata', 'manual')),
  created_at timestamptz not null default now(),
  primary key (calendar_connection_id, occurrence_key, user_id),
  foreign key (household_id, user_id)
    references public.household_members (household_id, user_id),
  foreign key (household_id, calendar_connection_id, occurrence_key)
    references public.calendar_event_occurrences (household_id, calendar_connection_id, occurrence_key)
);

create index calendar_occurrence_busy_members_lookup_idx
  on public.calendar_occurrence_busy_members (household_id, user_id, calendar_connection_id, occurrence_key);

-- ---------------------------------------------------------------------------
-- Manual busy classification (normalized; no uuid[] member array)
-- ---------------------------------------------------------------------------

create table public.calendar_busy_classifications (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  calendar_connection_id uuid not null,
  subject_event_id text not null,
  original_start_time_key text null,
  busy_scope text not null check (busy_scope in ('self', 'partner', 'family', 'unknown')),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, id),
  foreign key (household_id, calendar_connection_id)
    references public.calendar_connections (household_id, id),
  foreign key (household_id, created_by)
    references public.household_members (household_id, user_id)
);

create unique index uq_busy_class_series_default
  on public.calendar_busy_classifications (calendar_connection_id, subject_event_id)
  where original_start_time_key is null;

create unique index uq_busy_class_instance
  on public.calendar_busy_classifications (calendar_connection_id, subject_event_id, original_start_time_key)
  where original_start_time_key is not null;

create index calendar_busy_classifications_lookup_idx
  on public.calendar_busy_classifications
  (household_id, calendar_connection_id, subject_event_id, original_start_time_key);

create trigger set_updated_at
  before update on public.calendar_busy_classifications
  for each row execute function public.set_updated_at();

create table public.calendar_busy_classification_members (
  classification_id uuid not null,
  household_id uuid not null references public.households (id),
  user_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (classification_id, user_id),
  foreign key (household_id, classification_id)
    references public.calendar_busy_classifications (household_id, id),
  foreign key (household_id, user_id)
    references public.household_members (household_id, user_id)
);

create index calendar_busy_classification_members_lookup_idx
  on public.calendar_busy_classification_members (household_id, classification_id, user_id);

-- ---------------------------------------------------------------------------
-- Private Google watch / sync / write state
-- ---------------------------------------------------------------------------

create table private.google_watch_channels (
  channel_id text primary key,
  calendar_connection_id uuid not null,
  resource_id text not null,
  token_hash text not null,
  status text not null check (status in ('active', 'retiring', 'stopped', 'expired')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index google_watch_channels_lookup_idx
  on private.google_watch_channels (calendar_connection_id, status, expires_at);

create trigger set_updated_at
  before update on private.google_watch_channels
  for each row execute function public.set_updated_at();

create table private.google_sync_state (
  calendar_connection_id uuid primary key,
  next_sync_token text null,
  last_success_at timestamptz null,
  last_full_sync_at timestamptz null,
  last_error text null,
  updated_at timestamptz not null default now()
);

create trigger set_updated_at
  before update on private.google_sync_state
  for each row execute function public.set_updated_at();

create table private.google_sync_jobs (
  id uuid primary key default gen_random_uuid(),
  calendar_connection_id uuid not null,
  status text not null check (status in ('queued', 'processing', 'done', 'dead')),
  reasons jsonb not null default '[]'::jsonb,
  rerun_requested boolean not null default false,
  attempts int not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  lease_owner text null,
  lease_token uuid null,
  lease_until timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    status not in ('processing')
    or (lease_owner is not null and lease_token is not null and lease_until is not null)
  ),
  check (
    status not in ('done', 'dead')
    or (lease_owner is null and lease_token is null and lease_until is null)
  )
);

create unique index google_sync_jobs_one_active_per_calendar_idx
  on private.google_sync_jobs (calendar_connection_id)
  where status in ('queued', 'processing');

create index google_sync_jobs_queue_idx
  on private.google_sync_jobs (status, next_attempt_at, lease_until, created_at);

create trigger set_updated_at
  before update on private.google_sync_jobs
  for each row execute function public.set_updated_at();

create table private.google_event_staging (
  sync_run_id uuid not null,
  calendar_connection_id uuid not null,
  google_event_id text not null,
  event_json jsonb not null,
  received_at timestamptz not null default now(),
  primary key (sync_run_id, google_event_id)
);

create index google_event_staging_run_idx
  on private.google_event_staging (calendar_connection_id, sync_run_id);

create table private.google_write_operations (
  operation_id uuid primary key,
  household_id uuid not null,
  calendar_connection_id uuid not null,
  google_event_id text not null,
  action text not null check (action in ('create', 'update')),
  request_hash text not null,
  status text not null check (status in ('pending', 'succeeded', 'conflict', 'dead')),
  result_etag text null,
  last_error text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (calendar_connection_id, google_event_id)
);

create trigger set_updated_at
  before update on private.google_write_operations
  for each row execute function public.set_updated_at();

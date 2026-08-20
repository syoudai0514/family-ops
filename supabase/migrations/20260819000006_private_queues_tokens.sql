-- WP1: private queues / one-time tokens / LINE quota / mutation+dispatch receipts
-- docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #14-#17,#20,#22; 15_DDL_CONTRACT.md #10,#16,#18,#22,#23
-- No placeholder "jsonb-only queue" implementation — exact columns per contract.

create table private.webhook_inbox (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('line')),
  provider_event_id text not null,
  source_external_user_id text null,
  payload jsonb not null,
  status text not null default 'received' check (status in ('received', 'processing', 'done', 'dead')),
  attempts int not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  lease_owner text null,
  lease_token uuid null,
  lease_until timestamptz null,
  last_started_at timestamptz null,
  last_error text null,
  received_at timestamptz not null default now(),
  processed_at timestamptz null,
  unique (provider, provider_event_id)
);

create index webhook_inbox_queue_idx
  on private.webhook_inbox (status, next_attempt_at, lease_until, received_at);

create table private.line_user_links (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null,
  user_id uuid not null,
  line_user_id text not null,
  status text not null default 'active' check (status in ('active', 'unlinked')),
  linked_at timestamptz not null default now(),
  unlinked_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id),
  unique (line_user_id),
  foreign key (household_id, user_id)
    references public.household_members (household_id, user_id),
  check (
    (status = 'active' and unlinked_at is null)
    or (status = 'unlinked' and unlinked_at is not null)
  )
);

create index line_user_links_lookup_idx
  on private.line_user_links (line_user_id, status);

create trigger set_updated_at
  before update on private.line_user_links
  for each row execute function public.set_updated_at();

create table private.pending_actions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null,
  actor_id uuid not null,
  source text not null check (source in ('line', 'pwa')),
  action_type text not null,
  normalized_payload jsonb not null,
  operation_id uuid not null,
  status text not null default 'draft'
    check (status in ('draft', 'confirmed', 'queued', 'executing', 'succeeded', 'cancelled', 'expired', 'dead')),
  confirmed_at timestamptz null,
  expires_at timestamptz not null,
  attempts int not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  lease_owner text null,
  lease_token uuid null,
  lease_until timestamptz null,
  last_started_at timestamptz null,
  last_error text null,
  result_type text null,
  result_id uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (actor_id, operation_id),
  foreign key (household_id, actor_id)
    references public.household_members (household_id, user_id)
);

create index pending_actions_queue_idx
  on private.pending_actions (status, next_attempt_at, lease_until, expires_at);

create trigger set_updated_at
  before update on private.pending_actions
  for each row execute function public.set_updated_at();

create table private.raw_inputs (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null,
  author_user_id uuid not null,
  kind text not null check (kind in ('request_draft', 'handover_draft', 'natural_language')),
  raw_text text null,
  raw_payload jsonb null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  foreign key (household_id, author_user_id)
    references public.household_members (household_id, user_id),
  check (raw_text is not null or raw_payload is not null)
);

create index raw_inputs_expires_at_idx on private.raw_inputs (expires_at);

create table private.household_invites (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique,
  household_id uuid not null,
  created_by uuid not null,
  expires_at timestamptz not null,
  used_at timestamptz null,
  used_by uuid null,
  created_at timestamptz not null default now(),
  foreign key (household_id, created_by)
    references public.household_members (household_id, user_id),
  foreign key (household_id, used_by)
    references public.household_members (household_id, user_id)
);

create index household_invites_lookup_idx
  on private.household_invites (household_id, expires_at, used_at);

create table private.line_link_tokens (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique,
  household_id uuid not null,
  user_id uuid not null,
  expires_at timestamptz not null,
  used_at timestamptz null,
  created_at timestamptz not null default now(),
  foreign key (household_id, user_id)
    references public.household_members (household_id, user_id)
);

create index line_link_tokens_lookup_idx
  on private.line_link_tokens (user_id, expires_at, used_at);

create table private.google_oauth_states (
  state_hash text primary key,
  household_id uuid not null,
  user_id uuid not null,
  return_to text null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz null,
  foreign key (household_id, user_id)
    references public.household_members (household_id, user_id)
);

create index google_oauth_states_lookup_idx
  on private.google_oauth_states (expires_at, used_at);

-- ---------------------------------------------------------------------------
-- LINE notification outbox + quota (Family Ops hard cap independent of
-- provider plan — see docs/design/v6/06_LINE_INTEGRATION.md)
-- ---------------------------------------------------------------------------

create table private.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null,
  recipient_user_id uuid not null,
  channel text not null check (channel in ('line', 'in_app')),
  type text not null,
  payload jsonb not null,
  dedup_key text not null,
  provider_retry_key uuid null,
  provider_first_attempt_at timestamptz null,
  provider_retry_expires_at timestamptz null,
  business_expires_at timestamptz null,
  quota_reservation_id uuid null,
  priority text not null default 'normal' check (priority in ('critical', 'normal', 'reminder')),
  quota_fallback_allowed boolean not null default true,
  status text not null default 'queued'
    check (status in ('queued', 'sending', 'sent', 'fallback', 'delivery_unknown', 'dead')),
  attempts int not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  lease_owner text null,
  lease_token uuid null,
  lease_until timestamptz null,
  last_started_at timestamptz null,
  last_error text null,
  sent_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (recipient_user_id, channel, dedup_key),
  foreign key (household_id, recipient_user_id)
    references public.household_members (household_id, user_id)
);

create unique index notification_outbox_provider_retry_key_idx
  on private.notification_outbox (provider_retry_key)
  where provider_retry_key is not null;

create index notification_outbox_queue_idx
  on private.notification_outbox (status, next_attempt_at, lease_until, created_at);

create trigger set_updated_at
  before update on private.notification_outbox
  for each row execute function public.set_updated_at();

create table private.line_quota_state (
  billing_month date primary key,
  provider_limit int not null check (provider_limit >= 0),
  provider_consumed int not null check (provider_consumed >= 0),
  local_counted_success int not null default 0 check (local_counted_success >= 0),
  soft_budget int not null default 180,
  reserve int not null default 20,
  app_hard_cap int not null default 200 check (app_hard_cap = 200),
  last_provider_refresh_at timestamptz null,
  updated_at timestamptz not null default now()
);

create trigger set_updated_at
  before update on private.line_quota_state
  for each row execute function public.set_updated_at();

create table private.line_quota_reservations (
  id uuid primary key default gen_random_uuid(),
  billing_month date not null references private.line_quota_state (billing_month),
  notification_outbox_id uuid not null unique
    references private.notification_outbox (id),
  units int not null default 1 check (units = 1),
  status text not null check (status in ('reserved', 'committed', 'released', 'ambiguous')),
  provider_consumed_snapshot int not null,
  reserved_at timestamptz not null default now(),
  committed_at timestamptz null,
  released_at timestamptz null,
  updated_at timestamptz not null default now()
);

create index line_quota_reservations_month_status_idx
  on private.line_quota_reservations (billing_month, status);

create trigger set_updated_at
  before update on private.line_quota_reservations
  for each row execute function public.set_updated_at();

alter table private.notification_outbox
  add constraint notification_outbox_quota_reservation_fkey
  foreign key (quota_reservation_id) references private.line_quota_reservations (id);

create table private.worker_run_receipts (
  worker_kind text not null,
  logical_slot_key text not null,
  created_at timestamptz not null default now(),
  completed_at timestamptz null,
  result jsonb null,
  primary key (worker_kind, logical_slot_key)
);

-- ---------------------------------------------------------------------------
-- Japan holiday cache (Cabinet Office CSV is source of truth; checked-in
-- fixture is bootstrap/fallback — see scripts/seed_jp_holidays.mjs)
-- ---------------------------------------------------------------------------

create table private.jp_holidays (
  local_date date primary key,
  name text not null,
  source text not null default 'cao_csv',
  source_fetched_at timestamptz not null,
  updated_at timestamptz not null default now()
);

create trigger set_updated_at
  before update on private.jp_holidays
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Mutation idempotency + scheduled dispatch idempotency
-- ---------------------------------------------------------------------------

create table private.mutation_receipts (
  actor_id uuid not null,
  operation_id uuid not null,
  action_type text not null,
  request_hash text not null,
  result_type text null,
  result_id uuid null,
  result_payload jsonb null,
  created_at timestamptz not null default now(),
  primary key (actor_id, operation_id)
);

create table private.scheduled_dispatch_receipts (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null,
  schedule_kind text not null,
  scheduled_local_date date not null,
  recipient_user_id uuid not null,
  dispatch_slot_key text not null,
  notification_outbox_id uuid null references private.notification_outbox (id),
  created_at timestamptz not null default now(),
  unique (household_id, schedule_kind, scheduled_local_date, recipient_user_id)
);

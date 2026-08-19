-- WP1: notifications / routine automation schedules / check-in sessions / evening setup
-- docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #7,#8,#19,#21; 15_DDL_CONTRACT.md #23

create table public.user_notifications (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  recipient_user_id uuid not null,
  type text not null,
  title text not null,
  body text not null,
  payload jsonb not null default '{}'::jsonb,
  dedup_key text not null,
  read_at timestamptz null,
  created_at timestamptz not null default now(),
  foreign key (household_id, recipient_user_id)
    references public.household_members (household_id, user_id),
  unique (recipient_user_id, dedup_key)
);

create index user_notifications_recipient_idx
  on public.user_notifications (recipient_user_id, created_at desc);

create table public.notification_preferences (
  household_id uuid not null references public.households (id),
  user_id uuid not null,
  request_line boolean not null default true,
  handover_line boolean not null default true,
  calendar_line boolean not null default true,
  conflict_line boolean not null default true,
  routine_completion_line boolean not null default false,
  shopping_minor_line boolean not null default false,
  weekly_digest_line boolean not null default true,
  daily_assignment_line boolean not null default true,
  routine_checklist_line boolean not null default true,
  routine_checkin_prompt_line boolean not null default true,
  in_app boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (household_id, user_id),
  foreign key (household_id, user_id)
    references public.household_members (household_id, user_id)
);

create trigger set_updated_at
  before update on public.notification_preferences
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Routine automation schedules
-- ---------------------------------------------------------------------------

create table public.household_routine_schedules (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  schedule_kind text not null
    check (
      schedule_kind in (
        'weekly_digest', 'daily_assignment',
        'dropoff_checklist', 'dropoff_checkin',
        'pickup_checklist', 'pickup_checkin',
        'nonpickup_evening_checklist', 'nonpickup_evening_checkin'
      )
    ),
  weekday smallint null check (weekday is null or weekday between 1 and 7),
  local_time time not null,
  enabled boolean not null default true,
  schedule_version int not null default 1 check (schedule_version >= 1),
  updated_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, schedule_kind),
  foreign key (household_id, updated_by)
    references public.household_members (household_id, user_id),
  check (
    (schedule_kind = 'weekly_digest' and weekday is not null)
    or (schedule_kind <> 'weekly_digest' and weekday is null)
  )
);

create index household_routine_schedules_enabled_kind_idx
  on public.household_routine_schedules (household_id, enabled, schedule_kind);

create trigger set_updated_at
  before update on public.household_routine_schedules
  for each row execute function public.set_updated_at();

create table public.routine_checkin_sessions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  session_type text not null check (session_type in ('dropoff', 'pickup', 'nonpickup_evening')),
  scheduled_date date not null,
  assignee_id uuid not null,
  status text not null check (status in ('open', 'submitted', 'auto_closed', 'superseded')),
  opened_at timestamptz not null default now(),
  submitted_at timestamptz null,
  superseded_at timestamptz null,
  assignment_generation int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, session_type, scheduled_date, assignee_id),
  unique (household_id, id),
  foreign key (household_id, assignee_id)
    references public.household_members (household_id, user_id),
  check (status <> 'submitted' or submitted_at is not null),
  check (status <> 'superseded' or superseded_at is not null)
);

create index routine_checkin_sessions_lookup_idx
  on public.routine_checkin_sessions (household_id, scheduled_date, assignee_id, status);

create trigger set_updated_at
  before update on public.routine_checkin_sessions
  for each row execute function public.set_updated_at();

create table public.routine_checkin_session_items (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  session_id uuid not null,
  task_instance_id uuid not null,
  display_order int not null,
  created_at timestamptz not null default now(),
  unique (session_id, task_instance_id),
  foreign key (household_id, session_id)
    references public.routine_checkin_sessions (household_id, id),
  foreign key (household_id, task_instance_id)
    references public.task_instances (household_id, id)
);

create index routine_checkin_session_items_session_idx
  on public.routine_checkin_session_items (household_id, session_id);

-- ---------------------------------------------------------------------------
-- Evening routine setup (fresh household must configure this — no silent
-- empty-night state; see 07_EXTERNAL... configure-evening-routines contract)
-- ---------------------------------------------------------------------------

create table public.evening_routine_preferences (
  household_id uuid not null references public.households (id),
  task_definition_id uuid not null,
  weekday smallint not null check (weekday between 1 and 7),
  enabled boolean not null default true,
  assignee_strategy text not null
    check (assignee_strategy in ('pickup_assignee', 'nonpickup_adult', 'fixed')),
  fixed_assignee_id uuid null,
  scheduled_local_time time null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (household_id, task_definition_id, weekday),
  foreign key (household_id, task_definition_id)
    references public.task_definitions (household_id, id),
  foreign key (household_id, fixed_assignee_id)
    references public.household_members (household_id, user_id),
  check (
    (assignee_strategy = 'fixed' and fixed_assignee_id is not null)
    or (assignee_strategy <> 'fixed' and fixed_assignee_id is null)
  )
);

create trigger set_updated_at
  before update on public.evening_routine_preferences
  for each row execute function public.set_updated_at();

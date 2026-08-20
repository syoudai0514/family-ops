-- WP1: task templates / recurrence / task instances / requests / handovers / shopping
-- docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #2-#6; 15_DDL_CONTRACT.md #2,#3,#5,#6,#7

-- ---------------------------------------------------------------------------
-- Task templates
-- ---------------------------------------------------------------------------

create table public.task_definitions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  code text not null,
  title text not null,
  category text not null,
  routine_phase text not null default 'anytime'
    check (routine_phase in ('morning', 'evening', 'anytime')),
  completion_mode text not null check (completion_mode in ('whole', 'subtasks')),
  is_active boolean not null default true,
  sort_order int not null default 0,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, code),
  unique (household_id, id),
  foreign key (household_id, created_by)
    references public.household_members (household_id, user_id)
);

create index task_definitions_household_id_idx on public.task_definitions (household_id);

create trigger set_updated_at
  before update on public.task_definitions
  for each row execute function public.set_updated_at();

create table public.task_subtask_definitions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  task_definition_id uuid not null,
  title text not null,
  required boolean not null default true,
  sort_order int not null,
  unique (household_id, id),
  foreign key (household_id, task_definition_id)
    references public.task_definitions (household_id, id)
);

create index task_subtask_definitions_household_id_idx
  on public.task_subtask_definitions (household_id);
create index task_subtask_definitions_task_definition_id_idx
  on public.task_subtask_definitions (household_id, task_definition_id);

-- ---------------------------------------------------------------------------
-- Recurrence rules
-- ---------------------------------------------------------------------------

create table public.recurrence_rules (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  task_definition_id uuid not null,
  weekday smallint not null check (weekday between 1 and 7),
  slot_key text not null default 'default',
  assignee_strategy text not null default 'fixed'
    check (
      assignee_strategy in
      ('fixed', 'dropoff_assignee', 'pickup_assignee', 'nonpickup_adult', 'unassigned')
    ),
  planned_assignee_id uuid null,
  scheduled_local_time time null,
  conflict_window_minutes int not null default 60
    check (conflict_window_minutes between 0 and 720),
  effective_from date not null,
  effective_to date null,
  active boolean not null default true,
  version int not null default 1,
  supersedes_rule_id uuid null,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, id),
  foreign key (household_id, task_definition_id)
    references public.task_definitions (household_id, id),
  foreign key (household_id, planned_assignee_id)
    references public.household_members (household_id, user_id),
  foreign key (household_id, created_by)
    references public.household_members (household_id, user_id),
  foreign key (household_id, supersedes_rule_id)
    references public.recurrence_rules (household_id, id),
  check (effective_to is null or effective_to >= effective_from),
  check (
    (assignee_strategy = 'fixed' and planned_assignee_id is not null)
    or (assignee_strategy <> 'fixed' and planned_assignee_id is null)
  )
);

create index recurrence_rules_household_id_idx on public.recurrence_rules (household_id);

create trigger set_updated_at
  before update on public.recurrence_rules
  for each row execute function public.set_updated_at();

-- Exact DB exclusion constraint (not app-only lock fallback) per
-- 15_DDL_CONTRACT.md #6: only one active rule may cover a given
-- (household, task_definition, weekday, slot) for overlapping date ranges.
alter table public.recurrence_rules
  add constraint recurrence_rules_no_overlap
  exclude using gist (
    household_id with =,
    task_definition_id with =,
    weekday with =,
    slot_key with =,
    daterange(effective_from, coalesce(effective_to, 'infinity'::date), '[]') with &&
  )
  where (active);

-- ---------------------------------------------------------------------------
-- Task instances / subtask instances / events
-- ---------------------------------------------------------------------------

create table public.task_instances (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  task_definition_id uuid null,
  recurrence_rule_id uuid null,
  logical_occurrence_key text null,
  origin text not null check (origin in ('recurring', 'manual', 'request', 'calendar_assist')),
  title text not null,
  category text not null,
  routine_phase text not null check (routine_phase in ('morning', 'evening', 'anytime')),
  scheduled_date date not null,
  due_at timestamptz null,
  planned_assignee_id uuid null,
  completion_mode text not null check (completion_mode in ('whole', 'subtasks')),
  status text not null
    check (status in ('todo', 'in_progress', 'completed', 'skipped', 'cancelled')),
  actual_completed_by_id uuid null,
  completed_at timestamptz null,
  source text not null,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, id),
  foreign key (household_id, task_definition_id)
    references public.task_definitions (household_id, id),
  foreign key (household_id, recurrence_rule_id)
    references public.recurrence_rules (household_id, id),
  foreign key (household_id, planned_assignee_id)
    references public.household_members (household_id, user_id),
  foreign key (household_id, actual_completed_by_id)
    references public.household_members (household_id, user_id),
  foreign key (household_id, created_by)
    references public.household_members (household_id, user_id),
  check (
    (status = 'completed' and completed_at is not null)
    or (status <> 'completed' and completed_at is null)
  ),
  check (
    completion_mode <> 'subtasks' or actual_completed_by_id is null
  ),
  check (
    not (completion_mode = 'whole' and status = 'completed')
    or actual_completed_by_id is not null
  )
);

create unique index task_instances_logical_occurrence_key_idx
  on public.task_instances (household_id, logical_occurrence_key)
  where logical_occurrence_key is not null;

create index task_instances_household_id_idx on public.task_instances (household_id);
create index task_instances_scheduled_status_idx
  on public.task_instances (household_id, scheduled_date, status);
create index task_instances_assignee_scheduled_status_idx
  on public.task_instances (household_id, planned_assignee_id, scheduled_date, status);
create index task_instances_phase_scheduled_assignee_status_idx
  on public.task_instances (household_id, routine_phase, scheduled_date, planned_assignee_id, status);

create trigger set_updated_at
  before update on public.task_instances
  for each row execute function public.set_updated_at();

create table public.task_subtask_instances (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  task_instance_id uuid not null,
  source_definition_id uuid null,
  title text not null,
  required boolean not null default true,
  sort_order int not null,
  is_completed boolean not null default false,
  completed_by uuid null,
  completed_at timestamptz null,
  unique (household_id, id),
  foreign key (household_id, task_instance_id)
    references public.task_instances (household_id, id),
  foreign key (household_id, source_definition_id)
    references public.task_subtask_definitions (household_id, id),
  foreign key (household_id, completed_by)
    references public.household_members (household_id, user_id),
  check (
    (is_completed and completed_by is not null and completed_at is not null)
    or (not is_completed and completed_by is null and completed_at is null)
  )
);

create index task_subtask_instances_task_instance_id_idx
  on public.task_subtask_instances (household_id, task_instance_id);

create table public.task_events (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  task_instance_id uuid not null,
  actor_id uuid not null,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  source text not null,
  idempotency_key text null,
  created_at timestamptz not null default now(),
  foreign key (household_id, task_instance_id)
    references public.task_instances (household_id, id),
  foreign key (household_id, actor_id)
    references public.household_members (household_id, user_id)
);

create unique index task_events_idempotency_key_idx
  on public.task_events (household_id, idempotency_key)
  where idempotency_key is not null;
create index task_events_task_instance_id_idx
  on public.task_events (household_id, task_instance_id);

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

create table public.requests (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  requester_id uuid not null,
  recipient_id uuid not null,
  shared_title text not null,
  shared_message text null,
  due_at timestamptz null,
  status text not null
    check (status in ('pending', 'accepted', 'declined', 'completed', 'cancelled')),
  linked_task_instance_id uuid null unique,
  accepted_at timestamptz null,
  declined_at timestamptz null,
  completed_at timestamptz null,
  cancelled_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (household_id, requester_id)
    references public.household_members (household_id, user_id),
  foreign key (household_id, recipient_id)
    references public.household_members (household_id, user_id),
  foreign key (household_id, linked_task_instance_id)
    references public.task_instances (household_id, id),
  check (requester_id <> recipient_id),
  check (
    case status
      when 'pending' then
        accepted_at is null and declined_at is null
        and cancelled_at is null and completed_at is null
      when 'accepted' then
        accepted_at is not null and declined_at is null
        and cancelled_at is null and completed_at is null
      when 'declined' then
        declined_at is not null and accepted_at is null
        and cancelled_at is null and completed_at is null
      when 'cancelled' then
        cancelled_at is not null and accepted_at is null
        and declined_at is null and completed_at is null
      when 'completed' then
        accepted_at is not null and completed_at is not null
        and declined_at is null and cancelled_at is null
      else false
    end
  )
);

create index requests_household_id_idx on public.requests (household_id);
create index requests_recipient_status_due_idx
  on public.requests (household_id, recipient_id, status, due_at);

create trigger set_updated_at
  before update on public.requests
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Handovers
-- ---------------------------------------------------------------------------

create table public.handovers (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  author_id uuid not null,
  shared_text text not null,
  period text not null check (period in ('morning', 'day', 'evening', 'other')),
  categories text[] not null default '{}',
  occurred_on date not null,
  created_at timestamptz not null default now(),
  unique (household_id, id),
  foreign key (household_id, author_id)
    references public.household_members (household_id, user_id)
);

create index handovers_household_occurred_created_idx
  on public.handovers (household_id, occurred_on desc, created_at desc);

create table public.handover_reads (
  household_id uuid not null references public.households (id),
  handover_id uuid not null,
  user_id uuid not null,
  read_at timestamptz not null default now(),
  primary key (handover_id, user_id),
  foreign key (household_id, handover_id)
    references public.handovers (household_id, id),
  foreign key (household_id, user_id)
    references public.household_members (household_id, user_id)
);

create index handover_reads_household_id_idx on public.handover_reads (household_id);

-- ---------------------------------------------------------------------------
-- Shopping
-- ---------------------------------------------------------------------------

create table public.shopping_items (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  title text not null,
  purchase_method text not null
    check (purchase_method in ('store', 'online', 'either', 'undecided')),
  status text not null
    check (status in ('wanted', 'assigned', 'ordered', 'purchased', 'arrived', 'cancelled')),
  assignee_id uuid null,
  url text null,
  due_at timestamptz null,
  created_by uuid not null,
  ordered_at timestamptz null,
  purchased_at timestamptz null,
  arrived_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, id),
  foreign key (household_id, assignee_id)
    references public.household_members (household_id, user_id),
  foreign key (household_id, created_by)
    references public.household_members (household_id, user_id),
  check (
    (status in ('ordered', 'arrived') and ordered_at is not null)
    or (status = 'cancelled')
    or (status not in ('ordered', 'arrived', 'cancelled') and ordered_at is null)
  ),
  check (
    (status = 'arrived' and arrived_at is not null)
    or (status <> 'arrived' and arrived_at is null)
  ),
  check (
    (status = 'purchased' and purchased_at is not null)
    or (status <> 'purchased' and purchased_at is null)
  )
);

create index shopping_items_status_due_idx
  on public.shopping_items (household_id, status, due_at);

create trigger set_updated_at
  before update on public.shopping_items
  for each row execute function public.set_updated_at();

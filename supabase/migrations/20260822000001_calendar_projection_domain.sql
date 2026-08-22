-- UX v3.3: stable calendar classification and generated-mirror identity.
-- These columns deliberately live on domain records; neither title text nor
-- title/date equality is a valid source of truth for projection or dedupe.

alter table public.task_definitions
  add column if not exists calendar_visibility text not null default 'hidden'
    check (calendar_visibility in ('transport', 'special', 'hidden'));

update public.task_definitions
set calendar_visibility = case
  when code in ('dropoff', 'pickup') then 'transport'
  when routine_phase in ('morning', 'evening') then 'hidden'
  else 'special'
end
where calendar_visibility = 'hidden';

create table if not exists public.household_task_categories (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  code text not null,
  label text not null,
  icon_key text,
  accent_token text,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  is_system boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, code)
);

alter table public.household_task_categories enable row level security;
grant select on public.household_task_categories to authenticated;
create policy household_task_categories_select on public.household_task_categories
  for select to authenticated using (public.is_household_member(household_id));

insert into public.household_task_categories
  (household_id, code, label, icon_key, accent_token, sort_order, is_system)
select h.id, seed.code, seed.label, seed.icon_key, seed.accent_token, seed.sort_order, true
from public.households h
cross join (values
  ('medical', '医療', 'medical', 'red', 10),
  ('daycare_special', '保育園特別対応', 'daycare', 'orange', 20),
  ('lesson', '習い事', 'lesson', 'purple', 30),
  ('school', '学校行事', 'school', 'blue', 40),
  ('family', '家族予定', 'family', 'green', 50),
  ('work', '仕事', 'work', 'navy', 60),
  ('shopping', '買い物', 'shopping', 'yellow', 70),
  ('other', 'その他', 'other', 'gray', 80)
) as seed(code, label, icon_key, accent_token, sort_order)
on conflict (household_id, code) do nothing;

alter table public.calendar_event_occurrences
  add column if not exists family_ops_mirror boolean not null default false,
  add column if not exists family_ops_kind text,
  add column if not exists family_ops_task_instance_id uuid references public.task_instances(id) on delete set null;

create index if not exists calendar_occurrences_family_ops_task_idx
  on public.calendar_event_occurrences (household_id, family_ops_task_instance_id)
  where family_ops_mirror;

-- A durable mapping used for PATCH/DELETE. provider_event_id is never
-- reconstructed from a title search.
create table if not exists private.family_ops_calendar_mirrors (
  household_id uuid not null references public.households(id) on delete cascade,
  projection_key text not null,
  kind text not null check (kind in ('transport', 'special')),
  local_date date not null,
  task_instance_id uuid references public.task_instances(id) on delete set null,
  calendar_connection_id uuid not null references public.calendar_connections(id) on delete cascade,
  provider_event_id text,
  sync_state text not null default 'pending' check (sync_state in ('pending', 'synced', 'failed', 'deleted')),
  last_error text,
  updated_at timestamptz not null default now(),
  primary key (household_id, projection_key)
);
revoke all on private.family_ops_calendar_mirrors from public, anon, authenticated;

-- WP1: households / profiles / household_members
-- docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #1; 15_DDL_CONTRACT.md #19, #20

-- Generic updated_at trigger. Trigger invocation does not require EXECUTE
-- privilege on the function, so this stays safely un-callable directly by
-- anon/authenticated (EXECUTE revoked in 20260819000009) while still firing
-- on every UPDATE.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create table public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  timezone text not null default 'Asia/Tokyo' check (timezone = 'Asia/Tokyo'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger set_updated_at
  before update on public.households
  for each row execute function public.set_updated_at();

create table public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  avatar_key text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

create table public.household_members (
  household_id uuid not null references public.households (id),
  user_id uuid not null references auth.users (id) on delete cascade,
  member_role text not null check (member_role in ('adult')),
  joined_at timestamptz not null default now(),
  primary key (household_id, user_id),
  unique (user_id) -- MVP: one household per user
);

create index household_members_household_id_idx on public.household_members (household_id);

comment on table public.household_members is
  'Canonical membership. actor_id/household_id are always server-derived from '
  'auth.uid() via this table, never trusted from client JSON payloads.';

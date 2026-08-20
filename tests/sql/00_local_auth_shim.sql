-- TEST-ONLY shim reproducing the minimal slice of a real Supabase project's
-- built-in auth/role contract needed to exercise RLS and function grants
-- against a plain local PostgreSQL cluster (no Docker/Supabase CLI needed).
--
-- This file is NEVER applied to a real Supabase project — Supabase already
-- provisions anon/authenticated/service_role roles and the auth schema
-- before any project migration runs. Applying this in production would be a
-- no-op at best (roles/schema already exist) and is explicitly out of the
-- supabase/migrations/ directory so it can never be picked up by
-- `supabase db push`/`db reset`.

create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text
);

-- Supabase's real auth.uid()/auth.role() read PostgREST's per-request GUCs
-- (request.jwt.claim.sub / request.jwt.claim.role), set from the verified
-- JWT for that request. We reproduce exactly that mechanism here: tests set
-- these GUCs with SET LOCAL before running as a given "user".
create or replace function auth.uid() returns uuid
language sql stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create or replace function auth.role() returns text
language sql stable
as $$
  select coalesce(current_setting('request.jwt.claim.role', true), current_setting('role'));
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator noinherit login password 'test' in role anon, authenticated, service_role;
  end if;
end;
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant select on auth.users to anon, authenticated, service_role;
-- Real Supabase user creation/deletion goes through GoTrue, not direct SQL;
-- these grants exist only so SQL test fixtures can create/delete auth.users
-- rows while impersonating service_role (matches how tests exercise
-- server_tx_* and, for DELETE, prove the hard-delete RESTRICT contract in
-- tests/sql/09_hard_delete_restrict.sql / docs/RUNBOOK.md).
grant insert, delete on auth.users to service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant execute on function auth.role() to anon, authenticated, service_role;

-- Postgres grants USAGE on schema public to PUBLIC by default; a real
-- Supabase project relies on that plus explicit table/function grants, which
-- is exactly what our migrations also assume.
grant usage on schema public to anon, authenticated, service_role;

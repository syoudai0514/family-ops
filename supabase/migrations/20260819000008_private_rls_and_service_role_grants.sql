-- WP1: private schema lockdown (defense in depth) + service_role privileges
-- docs/design/v6/04_SECURITY_RLS_PRIVACY.md #6; 15_DDL_CONTRACT.md #9

-- Enable RLS on every private table with zero policies as a second layer of
-- defense: even if a future migration accidentally grants schema USAGE or a
-- table privilege to anon/authenticated, no row becomes selectable without a
-- policy. service_role is not subject to RLS (BYPASSRLS in a real Supabase
-- project; see tests/sql/00_local_auth_shim.sql for the local equivalent).
do $$
declare
  t text;
begin
  for t in
    select tablename from pg_tables where schemaname = 'private'
  loop
    execute format('alter table private.%I enable row level security', t);
    execute format('revoke all on private.%I from public, anon, authenticated', t);
  end loop;
end;
$$;

-- Explicit per-table service_role grants (defense in depth alongside the
-- schema-level GRANT USAGE + default-privilege lock from migration 1).
do $$
declare
  t text;
begin
  for t in
    select tablename from pg_tables where schemaname = 'private'
  loop
    execute format('grant select, insert, update, delete on private.%I to service_role', t);
  end loop;
end;
$$;

-- service_role executes public.server_tx_* as SECURITY INVOKER (invoker =
-- service_role, since Edge Functions call RPC with the service-role client),
-- so it needs the same business-table DML the transaction functions perform.
-- service_role bypasses RLS, so this grant does not create any anon/
-- authenticated exposure.
do $$
declare
  t text;
begin
  for t in
    select tablename from pg_tables where schemaname = 'public'
  loop
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
  end loop;
end;
$$;

-- Any future table added to private/public by the migration role stays
-- browser-unreachable and service_role-usable automatically.
alter default privileges in schema private
  grant select, insert, update, delete on tables to service_role;
alter default privileges in schema public
  grant select, insert, update, delete on tables to service_role;

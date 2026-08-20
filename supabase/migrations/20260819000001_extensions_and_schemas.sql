-- WP1: extensions + private schema
-- docs/design/v6/15_DDL_CONTRACT.md #1, #9; 04_SECURITY_RLS_PRIVACY.md #6

-- gen_random_uuid()/sha256()/digest-by-encode are core PostgreSQL 13+/11+
-- functions; only the gist operator classes for recurrence_rules' exclusion
-- constraint require an extension.
create extension if not exists btree_gist schema public;

create schema if not exists private;

-- private schema is never an exposed/Data-API schema and is never reachable
-- by anon/authenticated/PUBLIC. service_role gets explicit USAGE below.
revoke all on schema private from public;
revoke all on schema private from anon;
revoke all on schema private from authenticated;

grant usage on schema private to service_role;

-- Lock default privileges now so every future object in these schemas is
-- browser-unreachable unless explicitly granted afterwards.
alter default privileges in schema private
  revoke all on tables from public, anon, authenticated;
alter default privileges in schema private
  revoke all on sequences from public, anon, authenticated;
alter default privileges in schema private
  revoke all on functions from public, anon, authenticated;

alter default privileges in schema public
  revoke all on functions from public, anon, authenticated;

-- Revoke default PUBLIC function EXECUTE that Postgres grants by default.
revoke execute on all functions in schema public from public;
revoke execute on all functions in schema private from public;

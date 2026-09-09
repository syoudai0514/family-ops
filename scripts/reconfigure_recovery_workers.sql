\set ON_ERROR_STOP on

-- Family Ops disaster-recovery worker reconfiguration.
--
-- This file intentionally contains NO project URL and NO worker token. Before
-- running it against the recovered target, the operator must:
--   1. deploy the CURRENT Family Ops Edge Functions to the target project;
--   2. set the target Edge secret CRON_WORKER_TOKEN to a NEW recovery token;
--   3. store that same token in Vault as `family_ops_worker_token`;
--   4. store the NEW target project URL in Vault as `family_ops_project_url`.
--
-- Routine restore drills do NOT run this file. They prove that no active
-- Family Ops jobs were copied from production. This script is only for an
-- intentional disaster-recovery cutover after the target has been validated.

DO $preflight$
BEGIN
  IF to_regclass('cron.job') IS NULL THEN
    RAISE EXCEPTION 'pg_cron is not available on the recovery target';
  END IF;
  IF to_regclass('net.http_request_queue') IS NULL THEN
    RAISE EXCEPTION 'pg_net is not available on the recovery target';
  END IF;
  IF to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE EXCEPTION 'Supabase Vault is not available on the recovery target';
  END IF;
  IF (SELECT count(*) FROM vault.decrypted_secrets WHERE name = 'family_ops_project_url') <> 1 THEN
    RAISE EXCEPTION 'Vault secret family_ops_project_url must exist exactly once';
  END IF;
  IF (SELECT count(*) FROM vault.decrypted_secrets WHERE name = 'family_ops_worker_token') <> 1 THEN
    RAISE EXCEPTION 'Vault secret family_ops_worker_token must exist exactly once';
  END IF;
END
$preflight$;

SELECT cron.schedule(
  'family-ops-calendar-outbox-v1',
  '* * * * *',
  $job$
    SELECT net.http_post(
      url := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'family_ops_project_url') || '/functions/v1/process-family-ops-calendar-outbox',
      headers := jsonb_build_object('Content-Type', 'application/json', 'X-Family-Ops-Worker-Token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'family_ops_worker_token')),
      body := '{}'::jsonb,
      timeout_milliseconds := 10000
    );
  $job$
);

SELECT cron.schedule(
  'family-ops-line-delivery-v1',
  '* * * * *',
  $job$
    SELECT net.http_post(
      url := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'family_ops_project_url') || '/functions/v1/send-notifications',
      headers := jsonb_build_object('Content-Type', 'application/json', 'X-Family-Ops-Worker-Token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'family_ops_worker_token')),
      body := '{}'::jsonb,
      timeout_milliseconds := 10000
    );
  $job$
);

SELECT cron.schedule(
  'family-ops-line-inbox-v1',
  '* * * * *',
  $job$
    SELECT net.http_post(
      url := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'family_ops_project_url') || '/functions/v1/process-line-inbox',
      headers := jsonb_build_object('Content-Type', 'application/json', 'X-Family-Ops-Worker-Token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'family_ops_worker_token')),
      body := '{}'::jsonb,
      timeout_milliseconds := 10000
    );
  $job$
);

SELECT cron.schedule(
  'family-ops-materialize-recurring-v1',
  '10 15 * * *',
  $job$
    SELECT net.http_post(
      url := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'family_ops_project_url') || '/functions/v1/materialize-recurring',
      headers := jsonb_build_object('Content-Type', 'application/json', 'X-Family-Ops-Worker-Token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'family_ops_worker_token')),
      body := '{}'::jsonb,
      timeout_milliseconds := 10000
    );
  $job$
);

SELECT cron.schedule(
  'family-ops-pending-actions-v1',
  '* * * * *',
  $job$
    SELECT net.http_post(
      url := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'family_ops_project_url') || '/functions/v1/process-pending-actions',
      headers := jsonb_build_object('Content-Type', 'application/json', 'X-Family-Ops-Worker-Token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'family_ops_worker_token')),
      body := '{}'::jsonb,
      timeout_milliseconds := 10000
    );
  $job$
);

SELECT cron.schedule(
  'family-ops-routine-dispatch-v1',
  '* * * * *',
  $job$
    SELECT net.http_post(
      url := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'family_ops_project_url') || '/functions/v1/dispatch-routine-automation',
      headers := jsonb_build_object('Content-Type', 'application/json', 'X-Family-Ops-Worker-Token', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'family_ops_worker_token')),
      body := '{}'::jsonb,
      timeout_milliseconds := 10000
    );
  $job$
);

DO $verify$
DECLARE
  expected_count integer;
BEGIN
  SELECT count(*) INTO expected_count
  FROM cron.job
  WHERE active
    AND (
      (jobname = 'family-ops-calendar-outbox-v1' AND schedule = '* * * * *') OR
      (jobname = 'family-ops-line-delivery-v1' AND schedule = '* * * * *') OR
      (jobname = 'family-ops-line-inbox-v1' AND schedule = '* * * * *') OR
      (jobname = 'family-ops-materialize-recurring-v1' AND schedule = '10 15 * * *') OR
      (jobname = 'family-ops-pending-actions-v1' AND schedule = '* * * * *') OR
      (jobname = 'family-ops-routine-dispatch-v1' AND schedule = '* * * * *')
    );

  IF expected_count <> 6 THEN
    RAISE EXCEPTION 'Family Ops recovery worker contract incomplete: expected 6 active jobs, found %', expected_count;
  END IF;

  IF (SELECT count(*) FROM cron.job WHERE jobname LIKE 'family-ops-%') <> 6 THEN
    RAISE EXCEPTION 'Unexpected Family Ops cron job exists after recovery worker setup';
  END IF;
END
$verify$;

SELECT jobname, schedule, active
FROM cron.job
WHERE jobname LIKE 'family-ops-%'
ORDER BY jobname;

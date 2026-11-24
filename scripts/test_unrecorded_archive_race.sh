#!/usr/bin/env bash
# Two real PostgreSQL connections: an in-flight progress record must win over
# an archive, even when it did not bump the parent task's revision.
set -euo pipefail
db_name="${1:?pass a scratch database name}"
psql_test() { psql -X -qAt -v ON_ERROR_STOP=1 -d "$db_name" "$@"; }
fail() { printf 'FAIL unrecorded archive race: %s\n' "$1" >&2; exit 1; }

actor_id="$(psql_test -c 'select gen_random_uuid()')"
psql_test -c "insert into auth.users(id) values ('$actor_id')" >/dev/null
household_id="$(psql_test -c "select public.server_tx_create_household('$actor_id',gen_random_uuid(),'archive race','A')->>'household_id'")"
task_id="$(psql_test -c "insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by) values ('$household_id','recurring','race fixture','household','morning',(now() at time zone 'Asia/Tokyo')::date-1,'unassigned','whole','todo','test','$actor_id') returning id")"

out_file="$(mktemp)"
error_file="$(mktemp)"
trap 'rm -f "$out_file" "$error_file"' EXIT
# The event's FK holds a KEY SHARE lock on its task until commit. The advisory
# lock signals that the insert happened while the transaction is still open.
psql_test >"$out_file" 2>&1 <<SQL &
begin;
insert into public.task_events(household_id,task_instance_id,actor_id,event_type,source)
  values ('$household_id','$task_id','$actor_id','work_progress_recorded','pwa');
select pg_advisory_xact_lock(8700133);
select pg_sleep(2);
commit;
SQL
event_pid=$!
ready=false
for _ in $(seq 1 50); do
  if [ "$(psql_test -c 'select pg_try_advisory_lock(8700133)')" = f ]; then ready=true; break; fi
  sleep 0.1
done
if [ "$ready" != true ]; then wait "$event_pid" || true; fail 'could not establish the in-flight event'; fi

result="$(psql_test -c "select private.fn_archive_unrecorded_routine_v1('$household_id','$task_id',(now() at time zone 'Asia/Tokyo')::date,1)")"
wait "$event_pid" || { cat "$out_file" >&2; fail 'event transaction failed'; }
case "$result" in *'"reason": "protected"'*) ;; *) fail "archive did not recheck the committed event: $result" ;; esac
state="$(psql_test -c "select status||':'||revision||':'||(select count(*) from private.unrecorded_routine_archives where task_id='$task_id') from public.task_instances where id='$task_id'")"
[ "$state" = 'todo:1:0' ] || fail "recorded task or snapshot changed: $state"

# In the opposite order, a user command that started with the old revision
# must fail rather than silently write over a committed archive.
task_id="$(psql_test -c "insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by) values ('$household_id','recurring','reverse race fixture','household','morning',(now() at time zone 'Asia/Tokyo')::date-1,'unassigned','whole','todo','test','$actor_id') returning id")"
psql_test >"$out_file" 2>&1 <<SQL &
begin;
select private.fn_archive_unrecorded_routine_v1('$household_id','$task_id',(now() at time zone 'Asia/Tokyo')::date,1);
select pg_advisory_xact_lock(8700134);
select pg_sleep(2);
commit;
SQL
archive_pid=$!
ready=false
for _ in $(seq 1 50); do
  if [ "$(psql_test -c 'select pg_try_advisory_lock(8700134)')" = f ]; then ready=true; break; fi
  sleep 0.1
done
if [ "$ready" != true ]; then wait "$archive_pid" || true; fail 'could not establish the in-flight archive'; fi
if psql_test -c "select public.server_tx_record_task_progress('$actor_id',gen_random_uuid(),'$task_id',1,'記録したい')" >"$error_file" 2>&1; then
  fail 'stale user recording unexpectedly succeeded'
fi
wait "$archive_pid" || { cat "$out_file" >&2; fail 'archive transaction failed'; }
grep -q 'AGGREGATE_REVISION_CONFLICT' "$error_file" || { cat "$error_file" >&2; fail 'unexpected recording failure'; }
state="$(psql_test -c "select status||':'||revision||':'||(select count(*) from private.unrecorded_routine_archives where task_id='$task_id')||':'||(select count(*) from public.task_events where task_instance_id='$task_id' and event_type='work_progress_recorded') from public.task_instances where id='$task_id'")"
[ "$state" = 'skipped:2:1:0' ] || fail "archive or concurrent recording changed unexpectedly: $state"
printf 'unrecorded_archive_race: PASS\n'

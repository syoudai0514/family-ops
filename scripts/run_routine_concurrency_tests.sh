#!/usr/bin/env bash
# Real-backend, deterministic routine checklist and materialization races. Run against the scratch
# database prepared by run_sql_tests.sh; no production schema hooks are needed.
set -euo pipefail

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5544}"
export PGUSER="${PGUSER:-postgres}"
TEST_DB="${1:-family_ops_sql_test}"
TEST_DIR=$(mktemp -d)
TEST_PREFIX="routine_race_${BASHPID}"
CHILD_PIDS=()
HOLDER_FD=''

cleanup() {
  local child
  if [ -n "$HOLDER_FD" ]; then exec {HOLDER_FD}>&-; fi
  for child in "${CHILD_PIDS[@]}"; do kill "$child" 2>/dev/null || true; done
  for child in "${CHILD_PIDS[@]}"; do wait "$child" 2>/dev/null || true; done
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL routine concurrency: $1" >&2
  local log
  for log in "$TEST_DIR"/*.log; do
    [ -f "$log" ] || continue
    echo "--- $(basename "$log") ---" >&2
    cat "$log" >&2
  done
  exit 1
}

sql() { psql -X -v ON_ERROR_STOP=1 -d "$TEST_DB" -q -t -A -c "$1"; }
sql_svc() { sql "set role service_role; $1"; }

wait_marker() {
  local marker="$1" log="$2" child="$3" attempt
  for ((attempt=0; attempt<160; attempt++)); do
    if grep -qFx "$marker" "$log"; then return; fi
    kill -0 "$child" 2>/dev/null || fail "backend ended before $marker"
    sleep 0.05
  done
  fail "backend did not reach $marker"
}

wait_blocked() {
  local blocked="$1" blocker="$2" child="${3:-}" attempt
  for ((attempt=0; attempt<160; attempt++)); do
    if [ "$(sql "select exists (
      select 1 from pg_stat_activity waiting, pg_stat_activity holding
      where waiting.application_name='$blocked'
        and holding.application_name='$blocker'
        and waiting.wait_event_type='Lock'
        and holding.pid=any(pg_blocking_pids(waiting.pid))
    );")" = t ]; then return; fi
    if [ -n "$child" ] && ! kill -0 "$child" 2>/dev/null; then return 1; fi
    sleep 0.05
  done
  if [ -n "$child" ]; then return 1; fi
  fail "$blocked did not block on $blocker"
}

start_holder() {
  local name="$1"
  HOLDER_LOG="$TEST_DIR/$name.log"
  mkfifo "$TEST_DIR/$name.fifo"
  PGAPPNAME="$name" psql -X -v ON_ERROR_STOP=1 -d "$TEST_DB" -q -t -A \
    < "$TEST_DIR/$name.fifo" > "$HOLDER_LOG" 2>&1 &
  HOLDER_PID=$!
  CHILD_PIDS+=("$HOLDER_PID")
  exec {HOLDER_FD}>"$TEST_DIR/$name.fifo"
  cat >&"$HOLDER_FD" <<'SQL'
set statement_timeout='15s';
set deadlock_timeout='200ms';
set role service_role;
begin;
SQL
}

finish_holder() {
  printf 'commit;\n\\q\n' >&"$HOLDER_FD"
  exec {HOLDER_FD}>&-
  HOLDER_FD=''
  wait "$HOLDER_PID" || fail "held transaction failed"
}

# One actual open occurrence with two required checks keeps each completion
# partial. A separate definition per case prevents cross-case snapshot effects.
make_fixture() {
  local label="$1"
  OWNER=$(sql 'select gen_random_uuid();')
  sql_svc "insert into auth.users(id) values('$OWNER');" >/dev/null
  HOUSEHOLD=$(sql_svc "select public.server_tx_create_household('$OWNER',gen_random_uuid(),'Routine race $label','Owner')->>'household_id';")
  DEFINITION=$(sql_svc "select public.server_tx_create_task_definition('$OWNER',gen_random_uuid(),'evening_chore_custom_race_$label','Race checklist','household','evening','whole',null,null)->>'task_definition_id';")
  sql_svc "select public.server_tx_replace_routine_subtasks('$OWNER',gen_random_uuid(),'$DEFINITION',
    '[{\"title\":\"Original A\",\"required\":true},{\"title\":\"Original B\",\"required\":true}]'::jsonb);" >/dev/null
  FIRST_DEFINITION=$(sql_svc "select id from public.task_subtask_definitions where task_definition_id='$DEFINITION' and title='Original A';")
  SECOND_DEFINITION=$(sql_svc "select id from public.task_subtask_definitions where task_definition_id='$DEFINITION' and title='Original B';")
  TASK=$(sql_svc "insert into public.task_instances
    (household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,completion_mode,status,source,created_by)
    values('$HOUSEHOLD','$DEFINITION','recurring','Race checklist','household','evening',
      (now() at time zone 'Asia/Tokyo')::date,'subtasks','todo','web','$OWNER') returning id;")
  sql_svc "insert into public.task_subtask_instances(household_id,task_instance_id,source_definition_id,title,required,sort_order)
    select household_id,'$TASK',id,title,required,sort_order from public.task_subtask_definitions
    where task_definition_id='$DEFINITION' and is_active;" >/dev/null
  FIRST_CHECK=$(sql_svc "select id from public.task_subtask_instances where task_instance_id='$TASK' and source_definition_id='$FIRST_DEFINITION';")
  EDIT_OPERATION=$(sql 'select gen_random_uuid();')
  COMPLETION_OPERATION=$(sql 'select gen_random_uuid();')
  EDIT_SQL="select public.server_tx_replace_routine_subtasks('$OWNER','$EDIT_OPERATION','$DEFINITION',
    jsonb_build_array(jsonb_build_object('id','$FIRST_DEFINITION','title','Edited A','required',true),
      jsonb_build_object('title','Added C','required',true)))::text;"
  COMPLETE_SQL="select public.server_tx_set_subtask_completion('$OWNER','$COMPLETION_OPERATION','$FIRST_CHECK',true,'self')::text;"
}

echo '== concurrency: waiting subtask completion leaves checklist rows unlocked =='
make_fixture lock_order
LOCKER_NAME="${TEST_PREFIX}_editor"
COMPLETER_NAME="${TEST_PREFIX}_completion"
start_holder "$LOCKER_NAME"
cat >&"$HOLDER_FD" <<SQL
select id from public.task_instances where id='$TASK' for update;
select 'PARENT_LOCKED';
SQL
wait_marker PARENT_LOCKED "$HOLDER_LOG" "$HOLDER_PID"

COMPLETER_LOG="$TEST_DIR/completion.log"
PGAPPNAME="$COMPLETER_NAME" psql -X -v ON_ERROR_STOP=1 -d "$TEST_DB" -q -t -A \
  > "$COMPLETER_LOG" 2>&1 <<SQL &
set statement_timeout='8s';
set deadlock_timeout='200ms';
set role service_role;
$COMPLETE_SQL
SQL
COMPLETER_PID=$!
CHILD_PIDS+=("$COMPLETER_PID")
wait_blocked "$COMPLETER_NAME" "$LOCKER_NAME"

# The holder now executes the real checklist RPC. The former child -> parent
# completion lock order creates a cycle here; parent -> child permits the edit
# to commit, after which the waiting completion records the retained check.
printf '%s\n' "$EDIT_SQL" >&"$HOLDER_FD"
finish_holder
wait "$COMPLETER_PID" || fail 'completion failed while racing with checklist edit'
grep -q '"ok": true' "$HOLDER_LOG" || fail 'checklist edit did not return success'
grep -q '"ok": true' "$COMPLETER_LOG" || fail 'completion did not return success'
[ "$(sql_svc "select exists(select 1 from public.task_subtask_instances
  where id='$FIRST_CHECK' and title='Edited A' and is_completed
    and completed_by='$OWNER' and completed_at is not null)
  and (select count(*) from public.task_subtask_instances where task_instance_id='$TASK')=2
  and exists(select 1 from public.task_subtask_instances where task_instance_id='$TASK' and title='Added C' and not is_completed)
  and exists(select 1 from public.task_instances where id='$TASK' and status='todo')
  and exists(select 1 from public.task_events where task_instance_id='$TASK' and idempotency_key='$COMPLETION_OPERATION:subtask')
  and (select count(*) from private.mutation_receipts where actor_id='$OWNER'
    and operation_id in ('$EDIT_OPERATION','$COMPLETION_OPERATION') and result_payload->>'ok'='true')=2;")" = t ] \
  || fail 'racing edit/completion lost checklist identity, partial completion, event, or receipt'
echo 'OK: parent-first locks allow checklist edit and waiting completion to commit without deadlock'

echo '== concurrency: checklist edit preserves partial completion committed during its lock wait =='
make_fixture snapshot
COMPLETER_NAME="${TEST_PREFIX}_recorded"
EDITOR_NAME="${TEST_PREFIX}_waiting_editor"
start_holder "$COMPLETER_NAME"
cat >&"$HOLDER_FD" <<SQL
$COMPLETE_SQL
select 'PARTIAL_RECORDED';
SQL
wait_marker PARTIAL_RECORDED "$HOLDER_LOG" "$HOLDER_PID"

EDITOR_LOG="$TEST_DIR/waiting_editor.log"
PGAPPNAME="$EDITOR_NAME" psql -X -v ON_ERROR_STOP=1 -d "$TEST_DB" -q -t -A \
  > "$EDITOR_LOG" 2>&1 <<SQL &
set statement_timeout='8s';
set deadlock_timeout='200ms';
set role service_role;
$EDIT_SQL
SQL
EDITOR_PID=$!
CHILD_PIDS+=("$EDITOR_PID")
wait_blocked "$EDITOR_NAME" "$COMPLETER_NAME"
finish_holder
wait "$EDITOR_PID" || fail 'checklist editor failed after concurrent partial completion committed'
grep -q '"ok": true' "$EDITOR_LOG" || fail 'waiting checklist edit did not return success'
[ "$(sql_svc "select exists(select 1 from public.task_subtask_definitions
  where id='$FIRST_DEFINITION' and title='Edited A' and is_active)
  and exists(select 1 from public.task_subtask_definitions where task_definition_id='$DEFINITION' and title='Added C' and is_active)
  and exists(select 1 from public.task_subtask_instances where id='$FIRST_CHECK'
    and title='Original A' and is_completed and completed_by='$OWNER' and completed_at is not null)
  and (select count(*) from public.task_subtask_instances where task_instance_id='$TASK')=2
  and exists(select 1 from public.task_subtask_instances where task_instance_id='$TASK'
    and source_definition_id='$SECOND_DEFINITION' and title='Original B' and not is_completed)
  and not exists(select 1 from public.task_subtask_instances where task_instance_id='$TASK' and title in ('Edited A','Added C'))
  and exists(select 1 from public.task_instances where id='$TASK' and status='todo' and completion_mode='subtasks')
  and exists(select 1 from public.task_events where task_instance_id='$TASK' and idempotency_key='$COMPLETION_OPERATION:subtask');")" = t ] \
  || fail 'editor overwrote the partial checklist snapshot that committed during its row-lock wait'
echo 'OK: waiting checklist edit updates the template and preserves the committed partial snapshot'

echo '== concurrency: removing a check while completion waits rejects the stale check cleanly =='
make_fixture removed_check
LOCKER_NAME="${TEST_PREFIX}_removing_editor"
COMPLETER_NAME="${TEST_PREFIX}_removed_completion"
start_holder "$LOCKER_NAME"
cat >&"$HOLDER_FD" <<SQL
select id from public.task_instances where id='$TASK' for update;
select 'REMOVAL_PARENT_LOCKED';
SQL
wait_marker REMOVAL_PARENT_LOCKED "$HOLDER_LOG" "$HOLDER_PID"

COMPLETER_LOG="$TEST_DIR/removed_completion.log"
PGAPPNAME="$COMPLETER_NAME" psql -X -v ON_ERROR_STOP=1 -d "$TEST_DB" -q -t -A \
  > "$COMPLETER_LOG" 2>&1 <<SQL &
set statement_timeout='8s';
set deadlock_timeout='200ms';
set role service_role;
$COMPLETE_SQL
SQL
COMPLETER_PID=$!
CHILD_PIDS+=("$COMPLETER_PID")
wait_blocked "$COMPLETER_NAME" "$LOCKER_NAME"
cat >&"$HOLDER_FD" <<SQL
select public.server_tx_replace_routine_subtasks('$OWNER','$EDIT_OPERATION','$DEFINITION',
  '[{"title":"Replacement","required":true}]'::jsonb)::text;
SQL
finish_holder
if wait "$COMPLETER_PID"; then fail 'completion accepted a check removed during its parent lock wait'; fi
grep -q 'ERROR:  CROSS_HOUSEHOLD_RESOURCE' "$COMPLETER_LOG" \
  || fail 'stale completion did not reject the removed check with CROSS_HOUSEHOLD_RESOURCE'
if grep -qi 'deadlock\|timeout' "$COMPLETER_LOG"; then fail 'removed-check completion deadlocked or timed out'; fi
[ "$(sql_svc "select not exists(select 1 from public.task_subtask_instances where id='$FIRST_CHECK')
  and (select count(*) from public.task_subtask_instances where task_instance_id='$TASK')=1
  and exists(select 1 from public.task_subtask_instances where task_instance_id='$TASK' and title='Replacement' and not is_completed)
  and not exists(select 1 from public.task_events where task_instance_id='$TASK' and idempotency_key='$COMPLETION_OPERATION:subtask')
  and not exists(select 1 from private.mutation_receipts where actor_id='$OWNER' and operation_id='$COMPLETION_OPERATION')
  and exists(select 1 from private.mutation_receipts where actor_id='$OWNER' and operation_id='$EDIT_OPERATION' and result_payload->>'ok'='true')
  and exists(select 1 from public.task_instances where id='$TASK' and status='todo' and completion_mode='subtasks');")" = t ] \
  || fail 'rejected stale completion left an orphan event, receipt, or checklist mutation'
echo 'OK: removed check is rejected after the lock wait and leaves no completion side effects'

# Pause finishes its occurrence scan while its definition update remains
# uncommitted. The materializer must wait for that same definition row, then
# re-read is_active=false. Without the shared lock it reads the former active
# value through MVCC and creates a todo that the completed pause scan misses.
# The live transaction is the barrier; no sleeps or test-only schema hooks
# determine which command gets to the race window first.
for materializer in rule batch; do
  echo "== concurrency: pause serializes with $materializer materialization =="
  make_fixture "pause_$materializer"
  RACE_DATE=$(sql "select ((now() at time zone 'Asia/Tokyo')::date
    +7+(7-extract(isodow from (now() at time zone 'Asia/Tokyo')::date))::int)::text;")
  RULE=$(sql_svc "insert into public.recurrence_rules
    (household_id,task_definition_id,weekday,slot_key,assignee_strategy,effective_from,active,created_by)
    values('$HOUSEHOLD','$DEFINITION',extract(isodow from date '$RACE_DATE')::int,
      'default','unassigned','$RACE_DATE',true,'$OWNER') returning id;")
  PAUSE_OPERATION=$(sql 'select gen_random_uuid();')
  PAUSER_NAME="${TEST_PREFIX}_pause_$materializer"
  MATERIALIZER_NAME="${TEST_PREFIX}_materialize_$materializer"
  start_holder "$PAUSER_NAME"
  cat >&"$HOLDER_FD" <<SQL
select public.server_tx_set_routine_definition_options(
  '$OWNER','$PAUSE_OPERATION','$DEFINITION',false,true,null)::text;
select 'PAUSE_SCANNED';
SQL
  wait_marker PAUSE_SCANNED "$HOLDER_LOG" "$HOLDER_PID"

  if [ "$materializer" = rule ]; then
    MATERIALIZE_SQL="select private.materialize_recurrence_rule('$HOUSEHOLD','$RULE','$RACE_DATE','$RACE_DATE');"
  else
    sql_svc "delete from private.worker_run_receipts
      where worker_kind='materialize-recurring' and logical_slot_key='$RACE_DATE';" >/dev/null
    MATERIALIZE_SQL="select public.server_tx_materialize_recurring_batch('$RACE_DATE')::text;"
  fi
  MATERIALIZER_LOG="$TEST_DIR/materialize_$materializer.log"
  PGAPPNAME="$MATERIALIZER_NAME" psql -X -v ON_ERROR_STOP=1 -d "$TEST_DB" -q -t -A \
    > "$MATERIALIZER_LOG" 2>&1 <<SQL &
set statement_timeout='15s';
set deadlock_timeout='200ms';
set role service_role;
$MATERIALIZE_SQL
SQL
  MATERIALIZER_PID=$!
  CHILD_PIDS+=("$MATERIALIZER_PID")
  if wait_blocked "$MATERIALIZER_NAME" "$PAUSER_NAME" "$MATERIALIZER_PID"; then
    SERIALIZED=true
  else
    SERIALIZED=false
  fi
  finish_holder
  wait "$MATERIALIZER_PID" || fail "$materializer materialization failed after pause committed"
  grep -q '"ok": true' "$HOLDER_LOG" || fail 'pause did not return success'
  if [ "$materializer" = batch ]; then
    grep -q '"already_ran": false' "$MATERIALIZER_LOG" || fail 'daily batch did not execute'
    grep -q '"failed": 0' "$MATERIALIZER_LOG" || fail 'daily batch hid a failed materialization'
  fi
  [ "$(sql_svc "select exists(select 1 from public.task_definitions
      where id='$DEFINITION' and not is_active)
    and exists(select 1 from public.task_instances where id='$TASK' and status='cancelled'
      and source_context ? 'routine_definition_pause')
    and not exists(select 1 from public.task_instances
      where task_definition_id='$DEFINITION' and status in ('todo','in_progress'))
    and not exists(select 1 from public.task_instances where recurrence_rule_id='$RULE')
    and exists(select 1 from public.recurrence_rules where id='$RULE' and active)
    and exists(select 1 from private.mutation_receipts where actor_id='$OWNER'
      and operation_id='$PAUSE_OPERATION' and result_payload->>'ok'='true');")" = t ] \
    || fail "$materializer materialization recreated work for the paused definition or lost its schedule"
  [ "$SERIALIZED" = true ] || fail "$materializer materialization skipped the shared definition lock"
  echo "OK: $materializer materialization waits for pause and creates no stopped-routine occurrences"
done

echo '== concurrency: bulk replacement locks uppercase UUID targets in UUID order =='
make_fixture uppercase_bulk
OTHER_DEFINITION=$(sql_svc "select public.server_tx_create_task_definition('$OWNER',gen_random_uuid(),
  'evening_chore_custom_race_bulk_other','Other race routine','household','evening','whole',null,null)->>'task_definition_id';")
LOWER_DEFINITION=$(sql "select least('$DEFINITION'::uuid,'$OTHER_DEFINITION'::uuid)::text;")
HIGHER_DEFINITION=$(sql "select greatest('$DEFINITION'::uuid,'$OTHER_DEFINITION'::uuid)::text;")
BULK_OPERATION=$(sql 'select gen_random_uuid();')
LOCKER_NAME="${TEST_PREFIX}_bulk_locker"
BULK_NAME="${TEST_PREFIX}_uppercase_bulk"
start_holder "$LOCKER_NAME"
cat >&"$HOLDER_FD" <<SQL
select id from public.task_definitions where id='$LOWER_DEFINITION' for no key update;
select 'FIRST_DEFINITION_LOCKED';
SQL
wait_marker FIRST_DEFINITION_LOCKED "$HOLDER_LOG" "$HOLDER_PID"

BULK_LOG="$TEST_DIR/uppercase_bulk.log"
PGAPPNAME="$BULK_NAME" psql -X -v ON_ERROR_STOP=1 -d "$TEST_DB" -q -t -A \
  > "$BULK_LOG" 2>&1 <<SQL &
set statement_timeout='15s';
set deadlock_timeout='200ms';
set role service_role;
select public.server_tx_replace_recurrence_schedule('$OWNER','$BULK_OPERATION',
  jsonb_build_array(
    jsonb_build_object('task_definition_id',upper('$HIGHER_DEFINITION'),'rules',
      jsonb_build_array(jsonb_build_object('weekday',7,'assignee_strategy','unassigned'))),
    jsonb_build_object('task_definition_id',upper('$LOWER_DEFINITION'),'rules',
      jsonb_build_array(jsonb_build_object('weekday',7,'assignee_strategy','unassigned')))
  ))::text;
SQL
BULK_PID=$!
CHILD_PIDS+=("$BULK_PID")
wait_blocked "$BULK_NAME" "$LOCKER_NAME"

# The payload asks for the higher UUID first. If uppercase JSON UUIDs were
# compared as case-sensitive text, prelocking would skip both definitions:
# the command would hold the higher definition and wait on our lower one.
# Taking the higher row now would form a real backend deadlock. UUID-typed,
# sorted prelocking leaves that row free until the lower lock is available.
printf "select id from public.task_definitions where id='%s' for no key update;\n" \
  "$HIGHER_DEFINITION" >&"$HOLDER_FD"
finish_holder
wait "$BULK_PID" || fail 'uppercase bulk replacement failed while taking its target locks'
grep -q '"replaced": 2' "$BULK_LOG" || fail 'uppercase bulk replacement did not save both routines'
[ "$(sql_svc "select (select count(*) from public.recurrence_rules
    where task_definition_id in ('$LOWER_DEFINITION','$HIGHER_DEFINITION') and active
      and weekday=7 and assignee_strategy='unassigned')=2
  and exists(select 1 from private.mutation_receipts where actor_id='$OWNER'
    and operation_id='$BULK_OPERATION' and result_payload->>'replaced'='2');")" = t ] \
  || fail 'uppercase bulk replacement lost a schedule or its mutation receipt'
echo 'OK: uppercase UUID bulk targets are locked in stable order before payload order runs'

echo '== routine concurrency tests passed =='

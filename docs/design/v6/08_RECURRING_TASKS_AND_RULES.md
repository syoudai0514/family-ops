# 08. Recurring Tasks / Rules — v6 normative

## 1. Weekly row model

One weekday per recurrence rule row.
ISO Monday=1 ... Sunday=7.

## 2. Stable occurrence identity

`rec:{task_definition_id}:{scheduled_date}:{slot_key}`

Rule ID/version is not part of occurrence identity.

## 3. Scheduled time

Each recurrence rule may have `scheduled_local_time`.

Materializer:
1. fixed timezone `Asia/Tokyo`
2. scheduled date
3. local time
4. convert to timestamptz `due_at`

No local time => due_at null.

Dropoff/pickup actual time must be entered in initial setup; Sonnet must not guess a clock time from family description.

`conflict_window_minutes` defaults 60.

## 4. Assignee strategy

Recurrence rules support:
- `fixed`
- `dropoff_assignee`
- `pickup_assignee`
- `nonpickup_adult`
- `unassigned`

Resolution happens during materialization for each date, and the resolved user is snapshotted into task_instance.planned_assignee_id.

Order:
1. materialize/resolve dropoff and pickup fixed rules
2. resolve dependent role-based rules
3. if role cannot resolve, leave unassigned and surface setup warning

No cycle is allowed. `dropoff` and `pickup` definitions cannot themselves use dropoff/pickup/nonpickup role strategies.

This allows Monday bedding / Tuesday gym / Thursday English preparation to follow that day's **dropoff assignee** without duplicating weekday-specific user IDs. It also allows household setup to assign some evening routines to `pickup_assignee` or `nonpickup_adult` if desired.

## 5. Routine phase

Task definition/instance snapshot:
- morning
- evening
- anytime

Scheduled LINE checklist selection uses this field plus planned assignee.

Dropoff/pickup themselves remain category/code identities and may be included explicitly in role session.

## 6. Materialization

Daily 00:10 Asia/Tokyo + on recurrence change.
Horizon today through +14 days.

Upsert by stable logical occurrence key.

## 7. Once change

Changing only one date:
- do not modify recurrence rule
- update task instance planned assignee
- event `reassigned_once`
- if today, routine sessions reconcile/supersede
- if scheduled notifications already sent, enqueue assignment-change message to both adults

## 8. Future rule change

- close old effective_to day before new effective_from
- insert new rule
- future `todo` occurrence reconcile
- `in_progress` unchanged
- completed/skipped/cancelled immutable

## 9. Overlap prevention

v6 fixed implementation:
- enable `btree_gist`
- Postgres exclusion constraint on household/task/weekday/slot + effective date range
- no fallback `SELECT FOR UPDATE` implementation choice

Migration test must prove overlapping insert fails under concurrency.

## 10. Partner handled

Planned assignment remains history.

Whole:
- complete actual_completed_by=partner

Subtask:
- selected subtasks completed_by=partner
- task-level actual_completed_by remains null

## 11. Special preparation normalization

No `special_preparations` pseudo-schema.
Create ordinary task definitions + recurrence rules:
- monday_bedding
- monday_uwabaki
- tuesday_gym_gear
- thursday_english_gear

routine_phase=`morning`.
Seed uses `assignee_strategy=dropoff_assignee` for these preparation rules because the user explicitly wants the dropoff assignee to receive the morning checklist. The resolved planned assignee is snapshotted into each task instance.

Pool-day preparation is not fixed weekday in MVP; create manual/calendar-assist task when needed.

## 12. Timezone tests

- Asia/Tokyo local due time -> correct UTC instant
- due_at changes for future todo when scheduled time rule changes
- historical task due_at remains unchanged

## v6 timezone decision

Family Ops MVPは日本家庭専用として`Asia/Tokyo`固定。
- timezone変更UIなし
- DST generic behaviorはMVP acceptance対象外
- `materialize-recurring` Cron = 00:10 JST daily
- local date/time -> timestamptz conversionはAsia/Tokyoのみ


## v6 evening setup

Fresh household must complete setup step `夜の定例タスク` before routine automation Ready.

For dinner/bath/laundry/dishes/cleaning/smile_zemi/media_30min:
- weekdays
- strategy=`nonpickup_adult|pickup_assignee|fixed|disabled`
- fixed assignee if fixed
- optional local time

Default proposal may be nonpickup_adult, but requires explicit confirmation.
`configure-evening-routines` atomically writes preferences+recurrence rules and triggers targeted materialization.


## v6 nonworkday applicability

Weekend/holiday notification mode is separate from task recurrence.
Task instances may exist, but weekday role notifications are suppressed and aggregated into 09:00/20:00 nonworkday flow.

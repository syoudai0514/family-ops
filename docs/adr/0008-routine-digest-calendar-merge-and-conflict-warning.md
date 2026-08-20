# 0008. Routine digest Calendar merge and conflict warning: design-detail
decisions

## Status

Accepted

## Context

Sol's independent design review flagged two P1 findings against
`20260819000082_dispatch_routine_automation_rpc.sql`'s own documented MVP
simplifications:

1. The Sunday weekly digest (and non-workday 09:00 daily section) omitted
   the Google Calendar occurrence merge (`17_ROUTINE_LINE_AUTOMATION.md` #3
   source 1) and the due request/shopping/manual-task highlights (#3 source
   5 / #7A "shared ToDo/shopping/request highlights").
2. The design-required assignment-conflict warning
   (`17_ROUTINE_LINE_AUTOMATION.md` #4, #3's own output example, and
   `notification_preferences.conflict_line`) was never implemented anywhere
   — `docs/adr/0006` had explicitly deferred it pending "a future WP" that
   turned out to be this one.

`20260819000091_dispatch_routine_automation_calendar_conflict.sql` closes
both. The v6 docs do not pin down every wording/threshold this required;
this ADR records the decisions made where they don't.

## Decisions

1. **"重要表示対象" (due-highlight importance) for #3 source 5.** No v6 doc
   defines this beyond "due dateのある...のうち重要表示対象" itself. Taken to
   mean: has a `due_at` falling within the digest's own relevant window
   (today's local date for the daily section; the upcoming Monday-Sunday
   week for the weekly section) and is still actionable — `requests.status
   in ('pending','accepted')`, `shopping_items.status in ('wanted',
   'assigned','ordered')`, `task_instances.status in ('todo','in_progress')`
   with `origin='manual'`. This is consistent with `02_UX_AND_SCREENS.md`
   §3's own "Today info priority" ordering, which ties importance to
   due/time proximity and open (not-yet-resolved) state rather than any
   separate importance flag — no such flag exists anywhere in the schema.

2. **Conflict window for `origin='manual'` task_instances.** `07_GOOGLE_
   CALENDAR.md` #10 says "conflict window default 60m per rule", and
   `recurrence_rules.conflict_window_minutes` (default 60) is the only place
   such a value is ever configured — `task_instances` itself has no
   per-instance conflict-window column. `origin='recurring'` instances
   inherit their rule's value via `task_instances.recurrence_rule_id`;
   every other origin (`manual`, `request`, `calendar_assist`) falls back to
   the same 60-minute default `recurrence_rules.conflict_window_minutes`
   itself defaults to, rather than inventing a second default value nowhere
   in the docs specifies.

3. **Conflict warning aggregation scope.** Both the `17_ROUTINE_LINE_
   AUTOMATION.md` #3 weekly-digest example and the #4 daily-assignment
   example show a single aggregate `⚠ 担当と予定の重なり N件` line, not one
   line per conflicting task or per viewing recipient. `private.fn_
   conflict_task_count()` is therefore computed household-wide (across
   whichever tasks/assignees are in the relevant date range, not filtered to
   the message's own recipient) for `daily_assignment`, the
   `nonworkday_morning_digest` today-section, and its weekly section alike.
   This does not weaken per-assignee correctness: the function's own busy-
   member join still requires `calendar_occurrence_busy_members.user_id =
   task_instances.planned_assignee_id`, so a conflict is only ever counted
   for the specific person the calendar occurrence and the task both agree
   is the same busy person — never "any adult in the household". Per-
   recipient personalization is applied only to whether the (identically-
   computed) warning text is appended at all, via each recipient's own
   `notification_preferences.conflict_line` — matching `#11`'s framing of
   `conflict_line` as a personal LINE-delivery toggle, not a data filter.

4. **No calendar-occurrence <-> task_instance dedup heuristic invented.**
   Sol's review asked for "no duplicate line when data sources describe the
   same logical household task", and the P1-1 fix does implement this for
   the one case the schema actually models a link for:
   `public.requests.linked_task_instance_id` — a due-request highlight is
   suppressed when its linked task is already shown in that recipient's own
   task list. `public.task_instances` has **no** column referencing
   `public.calendar_event_occurrences` (no `calendar_event_id`,
   `google_event_id`, or `occurrence_key` anywhere on `task_instances`), and
   no other table links the two. A calendar occurrence and a household task
   that merely happen to share a similar title/time are therefore always
   shown as two independent lines — inventing a fuzzy title/time-based dedup
   heuristic risks silently hiding a real, distinct calendar event, which is
   a worse failure mode than an occasional double line. `tests/sql/24_
   routine_digest_calendar_and_conflict.sql` scenario 3 (no-dedup case)
   asserts this directly.

## Consequences

- `private.fn_calendar_day_lines`, `private.fn_due_highlight_lines`, and
  `private.fn_conflict_task_count` are new, independently testable helper
  functions (`private` schema, `service_role`-only, same grant pattern as
  every other WP8 helper). Any future WP wanting Calendar-merge or
  conflict-count logic elsewhere can reuse them rather than re-deriving.
- If a future design update adds an explicit importance/priority flag to
  `requests`/`shopping_items`/`task_instances`, or a real calendar-event ->
  task_instance link column, decisions 1 and 4 above should be revisited —
  today's due-date/open-status and no-link reasoning would then be
  superseded by an explicit signal.

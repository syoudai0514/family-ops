# 09 — Transport period template / occurrence override / Month UX

Status: **CURRENT design contract**  
Authority: `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`, Appendix A Q1-Q112, accepted ADRs, and the user-approved `family-ops-ux-contract-final-v11-noscript.html` UI / Interaction Contract.

This document records the concrete transport/Month interaction that was user-confirmed during PR #50. It does not introduce production fixture chores, dates, or assignees from the HTML.

## 1. Period-scoped weekly transport template

Regular dropoff/pickup scheduling is edited as **one weekly template for one effective period**, not as seven independent recurring-rule forms.

A template contains:

- `household_id`
- `valid_from`
- `valid_to` (`NULL` = open-ended / 期限未定)
- exactly one row for each ISO weekday 1..7
- for each weekday, independently nullable `dropoff_user_id` / `pickup_user_id`
- optional dropoff/pickup local display/materialization times

The default creation path is open-ended. When a later template is inserted with `valid_from=D`, the immediately preceding open-ended template is automatically closed at `D - 1 day`. Active template periods must not overlap. Users are not required to manually maintain end dates in the normal flow.

`recurrence_rules` remain the execution/materialization primitive during compatibility rollout, but transport templates are the user-facing period coordinator. A template command updates the transport recurrence rules for its period atomically under the household transport advisory lock.

## 2. Precedence and protected future occurrences

Changing a weekly template recalculates only future occurrences that are still rule-derived. It must not silently rewrite a future occurrence that carries stronger individual intent, including:

- individually agreed assignment (`assignment_source='agreement'` or equivalent canonical agreement authority)
- an explicit occurrence override
- an explicit one-off reassignment / individually confirmed future occurrence
- other protected human-confirmed authority under the common Authority rules

The save command returns the bounded set of protected conflicts it did not rewrite. The UI tells the user that those exact individual occurrences were preserved and offers date-level editing rather than overwriting them.

This is the concrete implementation of the Q50/Q51 principle: template change is not newest-wins over individual agreement.

## 3. Occurrence override

A change such as “9/17だけ送りをパパ” is stored as a **date-scoped transport occurrence override**, separate from the weekly template.

The override can independently say whether dropoff and/or pickup is overridden and may select a household member or no assignee for that leg. Applying it changes only the matching materialized occurrence(s) for that date; it does not mutate:

- another date
- another weekday
- the period template rows
- the surrounding recurrence period

Deleting the override resolves the template that covers the date and restores the transport occurrence to that base template value. Override history uses a distinct event identity (`transport_override_applied`), so it is not confused with a separately negotiated/explicit `reassigned_once` agreement.

## 4. Google Calendar compact transport presentation

Domain data continues to store dropoff, pickup, and actor identity separately. Only narrow presentation surfaces create a compact title.

Exact representation:

- both: `送P迎M`
- dropoff only: `送P`
- pickup only: `迎M`

The compact string contains **no space and no separator**. `|`, `｜`, `/`, whitespace, and similar separators are prohibited.

`P`/`M` are presentation tokens derived from explicit household `family_role` (`papa` / `mama`), not join order, device-local “me”, event title parsing, or a guess. If an assigned actor cannot resolve to an explicit P/M role, compact provider projection fails closed instead of manufacturing a misleading title.

Google provider mutation remains asynchronous through the existing Family Ops calendar mirror/outbox owner. This presentation change does not create a second provider writer.

## 5. PWA Month interaction

Tapping a date in Month does **not** immediately navigate away or open the detail sheet. It first selects the date and renders an inline summary directly below the calendar.

The inline summary contains at minimum:

- `予定`
- `送迎`
- `主なToDo・準備`

The Month cell may show the exact compact transport token when space permits. The inline transport detail expands normal wording (for example `送り：パパ / 迎え：ママ`).

From the inline summary the user can choose:

- `詳しく見る・編集` → existing day detail/edit surface
- `この日に追加` → existing add form with the selected date prefilled
- `この日だけ変更` in transport → occurrence-override editor

The selected date remains in Month until the user changes month/date; opening and closing a child editor must not turn the date tap itself into navigation.

## 6. Mobile layout

The Month grid and weekly-template matrix must remain usable at iPhone-class widths, including <=390px. Compact transport is intentionally text-only in the month cell so it cannot acquire spacing/separator chrome that defeats the compact contract.

## 7. Regression contract

At minimum automated tests must cover:

1. exact `送P迎M`, `送P`, `迎M`
2. no whitespace or separator in compact transport
3. Month date selection → inline summary
4. inline summary → detail/edit and selected-date add
5. new template → previous template closes on the prior day
6. newest template open-ended by default
7. template period non-overlap
8. occurrence override does not mutate template
9. deleting override restores base template
10. protected individual agreement is surfaced and not silently overwritten
11. cross-household assignee rejection
12. idempotent template mutation does not duplicate a period

## 8. Relationship to the rest of the final HTML contract

The HTML remains the final UI / Interaction Contract for the broader PR #50 flow. In particular this design does not weaken the existing main path:

`Today summary → 要対応へのdirect navigation → parent task/subtask → その場完了 → 夜の残り実績 → 全部/大体/個別 → 戻り/state restoration`.

The transport changes are integrated into that same PWA/LINE product rather than forming a separate scheduler UI.

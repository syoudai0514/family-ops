# おうちノート — User-approved UX deltas after final audit

This file records user-approved refinements made after the first final UX audit. It is an implementation handoff delta and does not supersede canonical requirements.

## 1. Compact transport token for narrow calendar surfaces

For month cells and Google Calendar event titles, use the shortest stable transport token:

- both legs: `送P迎M`
- dropoff only: `送P`
- pickup only: `迎M`

Rules:

- no spaces
- no `|` / `｜` / `/` separator
- actor initials use half-width Latin letters
- detailed views may expand to `送り：パパ / 迎え：ママ`
- the compact token is a presentation rule only; canonical assignment data remains structured and separate

Reason: Google Calendar month cells truncate narrow event titles. `送P | 迎M` can hide the pickup actor; `送P迎M` preserves both legs in substantially less width.

## 2. Month calendar interaction

Month view must support this primary path:

**日を選択 → カレンダーを残したまま直下に、その日の予定・送迎・ToDoをざっと表示 → 必要なときだけ詳細/編集**

The month cell itself may show compact high-value labels such as `送P迎M`. The inline selected-day summary expands the meaning and provides `詳しく見る・編集` / add actions.

Do not force every date tap directly into a full-screen detail view.

## 3. Routine transport rules are period templates

The user-facing mental model is not “create one weekday rule repeatedly”. It is:

**one weekly transport template per validity period**.

Example:

- Template A: `2026/9/1 – 2026/9/30`
- Template B: `2026/10/1 – indefinite`

Default end state is **indefinite / no end date**.

When a new future template starts, automatically close the immediately preceding open-ended template on the previous day:

- before: A = `2026/9/1 – indefinite`
- add B starting `2026/10/1`
- after: A = `2026/9/1 – 2026/9/30`, B = `2026/10/1 – indefinite`

Requirements:

- period templates must not overlap
- normal UI should avoid making users manually maintain end dates
- past templates remain visible as history
- only base-rule-derived future occurrences are recalculated
- explicit occurrence overrides / individual agreements are not silently overwritten
- same-range future conflicts should be reviewed in a grouped way rather than occurrence-by-occurrence

## 4. Day-level override remains a separate layer

A single-day change must not rewrite the period template.

Example:

- base template for 9/17: dropoff Mama / pickup Mama
- one-day override: dropoff Papa / pickup stays Mama

Store and present this as an occurrence/day override. Removing the override returns that date to the applicable period template.

## 5. Prototype fixture rule

Names of chores, events, dates, assignees, subtasks and counts shown in the UX prototype are **fixtures for demonstrating interaction only**.

They are not required default chores, seed data, or mandatory household rules.

In particular, do not infer product defaults such as bath cleaning or drain cleaning from prototype examples. Production surfaces must render household-configured/current data.

## 6. Canonical follow-through required in PR #50

Before independent final re-review, the implementation branch should update the canonical requirements/design text so the following approved decisions are not left only in chat/prototype documentation:

1. weekly transport rule UI/model = period-scoped template, default end = indefinite;
2. inserting a later template auto-closes the prior open-ended period at the previous day;
3. occurrence/day override remains independent from the period template;
4. month view date selection shows an inline day summary before full detail;
5. compact transport presentation token for narrow calendar surfaces = `送P迎M` / `送P` / `迎M`.

These refinements are compatible with the existing canonical principles for validity-period weekday rules, occurrence overrides, preservation of individual agreements, Month/Day detail, and compact transport display; they make the user-facing contract more concrete.

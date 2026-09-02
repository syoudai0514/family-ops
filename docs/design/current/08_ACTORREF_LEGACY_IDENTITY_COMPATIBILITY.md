# 08. ActorRef / Legacy Identity Compatibility Contract

## 1. Purpose

`02_DATA_MODEL_AND_MIGRATION.md` defines `domain_actor_refs` as the canonical actor identity for new semantics. This document closes the concrete compatibility boundary with CURRENT tables whose legacy identity columns are `uuid` references to real `household_members` and, in some cases, `NOT NULL` or part of a key.

This is normative for the detailed-design review and **overrides any earlier wording that implies a simulated actor can be persisted by reusing a real-user-only legacy column**.

No fake auth user/member and no operator-user-ID substitution is allowed.

## 2. Core rule

Every actor-bearing new semantic fact has two different identity concerns:

1. **operator/auth principal** — the real user whose JWT/LINE link authorized the command;
2. **domain actor** — who the domain action represents (`real_user`, `simulated_member`, `system`).

They may be the same in production, but in one-user simulation they are intentionally different.

`domain_actor_refs.id` is canonical for domain actor truth.

A legacy real-user ID may remain only as:

- an authentication/operator field, or
- a production real-user compatibility mirror.

It is never canonical for simulated actor meaning.

## 3. Existing `requests`

CURRENT `requests.requester_id` / `recipient_id` are real-user member references.

Evolution:

- add `requester_actor_ref_id` and `recipient_actor_ref_id`.
- new runtime truth uses ActorRef.
- legacy requester/recipient user IDs remain compatibility mirrors for **production real-user requests only**.
- before test requests can be persisted, legacy requester/recipient NOT NULL constraints must be relaxed if CURRENT schema requires them.
- production check/transaction invariant:
  - `test_context_id IS NULL`
  - both actor refs are `real_user`
  - legacy requester/recipient user IDs are non-null and match ActorRef `real_user_id` during compatibility period.
- test check/transaction invariant:
  - `test_context_id IS NOT NULL`
  - actor refs belong to same test context/household as required
  - simulated side legacy user ID is null, never operator ID.

Production reads filter test rows; existing UI does not have to interpret null legacy recipient IDs.

## 4. Existing `task_events`

CURRENT `task_events.actor_id` is a real-user member ID and is `NOT NULL` in v6 design.

Evolution:

- add canonical `actor_ref_id` for new events.
- existing production events are backfilled to corresponding real-user ActorRef.
- for new production real-user event, legacy `actor_id` may mirror ActorRef `real_user_id` during compatibility.
- for simulated test event, legacy `actor_id` must be nullable and remain null.
- relaxing legacy `actor_id NOT NULL` is allowed only after:
  - actor_ref column/constraint exists,
  - existing rows are backfilled,
  - new command path always writes actor_ref,
  - production invariant requires a matching real-user actor mirror where needed for legacy reads.

History/read cutover uses ActorRef. The operator who authorized a simulated action is available separately through mutation/audit execution context; it is not stored as the task event actor.

## 5. Existing handover/share actor fields

CURRENT `handovers.author_id` and `handover_reads.user_id` are real-user based.

For the new common info/share/handover semantics:

- add `author_actor_ref_id` to current info representation.
- production real author may mirror legacy `author_id`.
- simulated test author uses ActorRef and must not mirror operator ID.

Because legacy `handover_reads` uses a real-user key, do **not** force simulated acknowledgement into that key.

Canonical new acknowledgement representation should be an ActorRef-capable receipt, e.g. `info_acknowledgements`:

- household_id
- info/handover id
- actor_ref_id
- acknowledged_at
- test_context_id nullable
- unique `(info_id, actor_ref_id)`

Existing production `handover_reads` can be backfilled/projected to this canonical receipt. During compatibility, production real acknowledgements may dual-project into legacy reads if required, but test simulated acknowledgements never fabricate `user_id`.

This replaces the weaker “handover_reads can always be reused directly” interpretation where its real-user PK would make simulation impossible.

## 6. Assignment / claim / actual / reconciliation

Canonical new fields are ActorRef-native from the start:

- task `planned_assignee_actor_ref_id`
- task `active_claimant_actor_ref_id`
- `task_actual_participants.actor_ref_id`
- `task_actual_participants.recorded_by_actor_ref_id`
- reconciliation session `actor_ref_id`

Legacy task `planned_assignee_id` / `actual_completed_by_id` may mirror production real actors only.

A simulated assignee/claimant/performer/recorder never writes operator user ID into these legacy mirrors.

## 7. Request attempts / confirmations

New tables are ActorRef-native:

- `request_attempts.created_by_actor_ref_id`
- `request_attempt_confirmations.actor_ref_id`

No real-user compatibility column is needed unless an existing consumer demonstrably requires one.

Consultation acceptance counts required domain ActorRefs, not authenticated operators.

## 8. Mutation receipts and operator provenance

CURRENT `private.mutation_receipts.actor_id` may remain the authenticated real operator identity for legacy/auth provenance if changing it would unnecessarily destabilize the existing idempotency mechanism.

For commands that can execute as a simulated actor, extend receipt identity with canonical semantic actor information:

- `actor_ref_id`
- `test_context_id` when test
- canonical request hash includes execution scope

New-operation uniqueness/replay semantics must distinguish:

- production papa action
- simulated mama action authorized by papa

The operator can be the same real user while domain actor differs.

Do not overload legacy `actor_id` to mean both operator and domain actor.

## 9. System actor

System/worker transitions that need semantic actor attribution use `actor_kind=system` ActorRef or an explicitly documented system actor reference.

Do not create fake household users for cron/worker actors.

Provider event identity/job IDs remain the idempotency source where appropriate.

## 10. Test scope hard constraints

DDL/transaction layer must guarantee:

- production aggregate (`test_context_id IS NULL`) cannot reference `simulated_member` ActorRef.
- test aggregate can reference simulated ActorRef only if household/test_context match.
- simulated ActorRef has no `real_user_id`.
- no simulated actor may satisfy a real-member FK by using operator user ID.
- production outbox/Google write cannot consume test aggregate/ActorRef.
- test rows remain excluded from production default reads/analytics.

Where PostgreSQL CHECK cannot reference another table, enforce using composite FK shape, trigger, transaction RPC validation, or a combination. The exact DDL mechanism is implementation detail; the invariant is not.

## 11. Migration order

1. create/backfill real-user ActorRefs.
2. add ActorRef columns/new ActorRef-native tables.
3. add compatibility projections/checks.
4. backfill existing actor-bearing production rows to real-user ActorRefs.
5. verify reconciliation: zero unresolved real rows before read cutover.
6. only then relax real-user-only legacy NOT NULL constraint where test rows require null legacy mirrors.
7. enable WP-DD3A test context/side-effect sandbox.
8. execute simulated identity E2E.
9. later cut production reads to ActorRef truth.
10. physical removal of legacy user-ID mirrors is separately reviewed cleanup.

No step rewrites existing actor history into simulated identity.

## 12. Mandatory reconciliation report

Before test mode enable:

- production request with actor ref not matching requester/recipient mirror = zero
- production task event without real-user ActorRef after backfill = zero or explicit legacy anomaly
- production actual participant mismatch = zero
- production aggregate referencing simulated ActorRef = zero

During test:

- simulated request recipient stored as operator user ID = zero
- simulated task performer/claimant/assignee/recorder stored as operator user ID = zero
- simulated confirmation in legacy real-user acknowledgement/confirmation field = zero

## 13. Mandatory E2E

One authenticated papa/operator:

1. creates test request to simulated mama;
2. simulated mama enters checking;
3. simulated mama accepts;
4. linked test task has simulated mama ActorRef as planned assignee;
5. simulated mama claims an anyone task;
6. simulated mama completes and is performer/recorder;
7. consultation stores papa real ActorRef confirmation and mama simulated ActorRef confirmation;
8. task/request/audit History displays `🧪 ママ`, not papa;
9. production LINE outbox/Google/real spouse consent remain untouched.

If any step requires fake auth/member or operator identity substitution, one-user test architecture is not ready.
# Family Ops / おうちノート
# F2 CONTROL TOWER HANDOFF — 2026-09-11

## 0. Role

This document hands the physical F2 work back to the **control tower / 司令塔** before a new F2 execution owner continues.

Do not treat this as permission to resume from old screenshots mechanically.

The control tower must:

1. fresh-read canonical Requirements/current design/CURRENT main;
2. verify that the Product Owner decisions discovered during physical F2 are now canonical;
3. freeze one new exact HEAD after this documentation change reaches main;
4. then hand only that frozen state to the new F2 owner.

## 1. Authority order

Use this order:

1. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
2. Appendix A Q1-Q112 / Q60-1 / Q60-2
3. `docs/design/current/`
4. Accepted ADRs
5. CURRENT GitHub source/schema
6. `docs/implementation/CF14-REQUIREMENT-EVIDENCE-MATRIX.md`
7. physical/device/provider evidence from the **same exact HEAD**

Old physical evidence from another HEAD is defect-discovery history, not final PASS evidence.

## 2. Product Owner decisions promoted from chat into canonical docs

The following are no longer chat-local decisions. They are normative in Baseline §28 and mapped into current design:

### Auth / household entry

- Email + password PWA auth remains supported alongside Google auth.
- Household adults may use different auth providers.

### LINE linking

- Successful LINE linking must explicitly say that linking succeeded.
- It must give short representative usage guidance.
- Silent successful claim is not acceptable.

### Natural LINE conversation

- Questions/corrections are resolved before mutation classification.
- `今日なんか予定あったっけ？` must not become a task/request draft.
- Natural schedule questions use a light conversational message followed by the canonical detailed result.
- Literal shortcut `今日` may remain compact.
- A clearly superseded erroneous draft may be canonically cancelled when the user corrects the interpretation.

### Request recipient UX

- A received request/assignment change must be actionable on LINE.
- First tier remains `やる / 難しい / その他の返答`.
- A text-only request notification is not sufficient.

### Transport weekly-template edit

- Re-saving the current/future period with the same `valid_from` edits the existing template in place.
- It must not create a duplicate period or collapse to a generic internal error.

### Transport-dependent work

- Accepted one-off pickup change re-resolves same-day unprotected `pickup_assignee` and unique `nonpickup_adult` tasks.
- Accepted one-off dropoff change re-resolves same-day unprotected `dropoff_assignee` tasks.
- Fixed assignments, individual agreements, explicit overrides, claims, cancelled/completed/terminal work remain protected.
- One-off transport agreement must not rewrite recurrence strategy or future dates.
- Ambiguous `nonpickup_adult` fails closed rather than guessing.

### F2 evidence topology

- One-user simulation remains supplementary.
- Two-party Request/assignment F2 requires separate real LINE participants on the final exact HEAD.

Canonical locations:

- Baseline §28
- current design 04 §26
- current design 09 §9
- current design 11 §4.2
- CF14 evidence matrix physical two-account update

## 3. Physical F2 defects found and remediated before this handoff

| Finding | Resolution | Production state before this docs PR |
|---|---|---|
| Natural question became task/request draft | read-only/correction routing before mutation | deployed |
| Natural answer felt command-like | two-message conversational lead + canonical detail | deployed |
| LINE link token claim succeeded silently | success + usage welcome | deployed |
| Request recipient received inert text only | preserve request payload through outbox + canonical `request.received` recognition + actionable Flex | deployed |
| Same-start transport template resave returned internal error | same-start in-place edit + typed transport errors | deployed |
| Accepted pickup changed only pickup task | role-dependent same-day task reconciliation merged in PR #84; CI #1045 / Operational Safety #140 GREEN | **production migration not yet applied at this handoff** |
| Existing already-accepted pickup request predated dependency fix | requires canonical reconciliation only after the production migration exists | **not yet backfilled; do not claim closed** |

## 4. Production runtime snapshot before this docs PR

CURRENT main after PR #85 documentation merge:

`9799dddd7ef497cf6ff6b4dad8fdbdc722997fd9`

PR #84 implementation status:

- PR #84 merged; merge commit `ad5e99d352230a94b1498c1262b32e6956f1a121`
- PR #84 head `7274444fbef08e940ceacfdb94ef21a146518ad9`
- CI #1045 GREEN
- Operational Safety #140 GREEN
- migration file on main: `20260911141000_transport_assignment_dependency_reconcile.sql`
- **production Supabase migration readback: NOT APPLIED as of 2026-09-11 16:39 JST**

Relevant production functions at this handoff:

- `process-line-inbox`: v30 ACTIVE
- `send-notifications`: v21 ACTIVE
- `transport-schedule`: v2 ACTIVE

Important runtime consequence:

- the latest real pickup assignment request was accepted before the dependency-reconcile migration existed;
- pickup itself moved to the mama test member;
- the same-day `pickup_assignee` dependents observed during F2 remained on papa at that point;
- do **not** state that those dependents were already backfilled or that the defect is production-closed.

Before freezing the next exact F2 HEAD, the control tower must reconcile CURRENT main vs production Supabase, apply the pending migration only after fresh verification, and then decide whether a one-time canonical repair of the already-accepted historical F2 request is needed for production consistency. A fresh final F2 scenario is still required regardless.

## 5. Important distinction: implementation closure vs final F2 evidence

Several defects were discovered using real devices and then fixed.

That does **not** mean the old screenshots become final evidence for the new HEAD.

After any code/docs HEAD change, strict CF14 evidence that requires exact HEAD must be rerun/rebound as required.

In particular, the accepted pickup request seen during defect discovery was accepted before the dependency-reconcile migration existed. Its dependent tasks were subsequently reconciled canonically for production consistency, but that is not a substitute for a fresh end-to-end request acceptance run on the final frozen HEAD.

## 6. OPEN observations not promoted to approved Requirements

These were observed but were **not** explicitly approved as new product behavior in this run. Keep them as control-tower findings until reviewed:

1. Household/family-role settings UI is visually confusing: selectors can look reversed even though DB family roles are correct.
2. `LINE_OA_BASIC_ID` is not configured in the production link-token response, so the PWA does not show a direct “open LINE and send code” path; LINE name search may not find the OA.

Do not silently mark these PASS. Decide whether they are F2 blockers, post-F2 UX follow-ups, or configuration work.

## 7. Safety / mutation boundaries

Still preserve:

- no real spouse notification;
- mama test member / separate test LINE is the recipient for two-account F2;
- no production Google Calendar mutation unless separately authorized;
- controlled/scratch Google provider resources only for F2 provider evidence;
- do not touch unrelated recovery namespaces/projects;
- no fake provider evidence, no DB-only substitution for LINE/provider PASS.

## 8. Control-tower actions before delegating

The control tower should perform these in order:

1. Fresh-read main after this documentation PR merges.
2. Confirm Baseline §28 and current design 04/09/11 are present.
3. Confirm all CI / Operational Safety checks for the docs PR are GREEN.
4. Confirm Vercel production is READY on the new main HEAD.
5. Confirm relevant Supabase runtime files/schema remain compatible with that HEAD.
6. **Resolve the pending production deployment gap for `20260911141000_transport_assignment_dependency_reconcile.sql`**. Do not infer deployment from PR merge/CI alone.
7. If production consistency requires repairing the already-accepted defect-discovery request, use the canonical reconciliation path after the migration is present and record that repair as operational consistency work, **not final F2 evidence**.
8. Confirm queues/safety after any production mutation.
9. Freeze **one** exact HEAD for the next F2 run.
10. Reclassify any old physical evidence from prior HEADs as stale/history where strict exact-head binding requires it.
11. Hand the frozen HEAD and the new-owner document to the new F2 owner.

Do not reopen already approved product decisions merely because an old implementation/test encoded different behavior.

## 9. Control-tower exit condition

Handoff to the new F2 owner only when:

- canonical docs contain all approved decisions above;
- CURRENT main is known;
- production deployment/runtime is known;
- no implementation branch intended for F2 remains unmerged;
- remaining F2 scenarios are explicitly listed;
- exact-head evidence rules are understood.


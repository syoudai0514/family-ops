# Issue #54 — Final UX Contract → Production Parity Matrix

Status: **PR #56 source remediation complete. User-approved defer recorded. Release may proceed before real-iPhone acceptance; physical Gate C is now a post-production acceptance step.**

## Authority

- Branch: `impl/issue-54-final-ux-parity`
- Product authority: `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` → Appendix A Q1–Q112 → `docs/design/current/` → Accepted ADRs → CURRENT source/schema.
- UI contract: `family-ops-ux-contract-final-v11-noscript.html`
- Contract SHA-256: `c1afa191a8e02f86683e886e0c59a60019b7388531dde19f96de690e8b9e2007`
- Prior independent reviewed head: `2f37e257b15f077940de27ef3821d7a4097b2e54` — NO-GO, BLOCKER 0 / HIGH 3 / MEDIUM 2 / LOW 0.
- Remediation implementation head: `8b66598cd942cb4cdc5dfcd2eb7624e46b8bf51f`.
- CI #719 / run `34087110663`: FULL GREEN.
- Verification head: `2e2782a27e6bf448b5d3c167a00754927e0ab008`.
- CI #720 / run `34087306529`: FULL GREEN.
- Re-review candidate before defer documentation: `8e12047354c1f2ed47561f022534b58bdb070e3c`.
- CI #722 / run `34087554001`: FULL GREEN across Web / Edge / DB / real Supabase CLI.

## User-approved deferred gap — Issue #58

The user explicitly removed **LINE / PWA Concierge service-level parity** from PR #56 release blocking scope and deferred it to follow-up Issue #58, `Concierge LINE / PWA service-level parity closeout`.

This is **not a requirement withdrawal**. Issue #58 owns completion of:

- equivalent user-visible natural-language understanding service level on LINE and PWA;
- multiple-intent decomposition;
- date / assignee / deadline interpretation;
- corrections such as `やっぱ土曜` and `ママじゃなくてパパ`;
- clarification of ambiguous parts only;
- candidate-level edit/cancel;
- AI-unavailable fallback;
- equivalent canonical truth after human confirmation;
- shared LINE/PWA service-level parity regression scenarios.

A common/shared internal implementation is explicitly **not** required. User-visible service-level equivalence is the requirement.

**This deferred cross-channel parity gap is excluded from PR #56 source-parity blocking calculation.** Do not mix Issue #58 implementation into PR #56 release work.

## PR #56 source parity

All currently in-scope source findings are remediated and deterministic CI is GREEN.

- In-scope source parity: **MATCH 33 / PARTIAL 0 / MISSING 0**.
- Deferred requirement track: **1 → Issue #58** (excluded from PR #56 denominator).
- Q1–Q112/canonical regression: **PASS**.
- Gate A: **PASS**.
- Gate B: **PASS for current PR #56 in-scope source parity**.
- Gate C: **POST-PRODUCTION ACCEPTANCE PENDING**; not a merge/deploy blocker by explicit user decision.
- Gate D/source remediation: previous five findings have been remediated; CI #722 FULL GREEN.

## Contract rows

| # | Contract item | PR #56 source status | Release note |
|---:|---|---|---|
| 1 | today | MATCH | physical iPhone check after production |
| 2 | checkin | MATCH | physical iPhone check after production |
| 3 | individual | MATCH | post-production acceptance |
| 4 | actual_add | MATCH | post-production acceptance |
| 5 | task_form | MATCH | post-production acceptance |
| 6 | task_detail | MATCH | post-production acceptance |
| 7 | groups | MATCH | post-production acceptance |
| 8 | requests | MATCH | post-production acceptance |
| 9 | request_form | MATCH | post-production acceptance |
| 10 | assignment | MATCH | post-production acceptance |
| 11 | routine_rules | MATCH | post-production acceptance |
| 12 | handover | MATCH | post-production acceptance |
| 13 | shopping | MATCH | post-production acceptance |
| 14 | anyone_owner | MATCH | post-production acceptance |
| 15 | event | MATCH | post-production acceptance |
| 16 | concierge | MATCH for PR #56 PWA behavior | LINE/PWA service-level equivalence deferred to Issue #58 |
| 17 | transcript | MATCH for PR #56 PWA behavior | cross-channel service-level parity deferred to Issue #58 |
| 18 | results | MATCH for PR #56 PWA behavior | cross-channel service-level parity deferred to Issue #58 |
| 19 | duplicate_review | MATCH | post-production acceptance |
| 20 | nursery | MATCH | safe post-production acceptance; no unnecessary provider mutation |
| 21 | google | MATCH | safe post-production acceptance; no unnecessary provider mutation |
| 22 | conflict_review | MATCH | post-production acceptance |
| 23 | week | MATCH | post-production acceptance |
| 24 | month | MATCH | post-production acceptance |
| 25 | dayagenda | MATCH | post-production acceptance |
| 26 | history | MATCH | post-production acceptance |
| 27 | notifications | MATCH | avoid unnecessary external delivery during acceptance |
| 28 | line_reference | MATCH | no real LINE mutation needed for acceptance |
| 29 | test_mode | MATCH | post-production acceptance |
| 30 | delete_semantics | MATCH | post-production acceptance |
| 31 | settings | MATCH | post-production acceptance |
| 32 | states | MATCH | post-production acceptance |
| 33 | non_ui_contract | MATCH | Q1–Q112 regression + canonical/RLS/CAS/idempotency/provider fences GREEN |
| 34 | coverage | RELEASE-SEQUENCED | real-iPhone evidence is intentionally recorded after production deployment, not used as source-parity failure |

## Remediated independent findings

1. Today first viewport literal/material labels restored.
2. Check-in shows concrete included/excluded names immediately before `全部やった`.
3. Concierge PWA proposal uses AI-first extraction with deterministic fallback and correction handling.
4. Results supports candidate editing and corrected request date/assignee reaches CURRENT canonical payload.
5. Durable docs no longer claim an unexecuted iPhone Gate C PASS.

## Release sequence — user approved

1. Record Issue #58 defer and exclude it from PR #56 release source parity.
2. Confirm final PR-head CI GREEN.
3. Merge PR #56 to `main` if no new blocker appears.
4. Apply production database migrations / Edge changes required by the merged source.
5. Confirm Vercel Production deployment from `main` only.
6. Confirm production health and key safe flows.
7. Execute real-iPhone Gate C against production and record exact production/main SHA plus observations.
8. If post-production Gate C finds a defect, fix only that defect in a dedicated release-fix path; do not mix Issue #58 scope.

## Safety

- Non-main Vercel Preview remains prohibited.
- Avoid real LINE / Google provider mutation unless explicitly necessary for a later acceptance scenario.
- Do not implement Issue #58 scope inside PR #56 release work.

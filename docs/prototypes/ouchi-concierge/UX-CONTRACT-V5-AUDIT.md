# おうちノート UX Contract v5 — UI requirements audit

## Purpose
This artifact is an implementation-facing UI/interaction contract, not a substitute for domain/security/concurrency contracts.

## Canonical sources checked
- `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- Appendix A Q1–Q112
- `docs/implementation/ISSUE-48-Q1-Q112-CONFORMANCE-MATRIX.md` on PR #50 head at review time
- CURRENT PR #50 source for Today/Checkin/History/Requests/Nursery/Shopping navigation

## v5 changes driven by gap review
1. Added Today-first situation summary with direct links.
2. Added priority hierarchy: first attention / unusual / handover / done / own work.
3. Added subtask progress and direct subtask checking.
4. Bulk-completion scope explicitly shows required/normal subtasks and excludes spare-capacity subtasks.
5. Added waiting state + next-check presentation.
6. Added unassigned and anyone-owner surfaces.
7. Added request states and separate work/reply deadline display.
8. Added handover confirmation vs read-only acknowledgement.
9. Added shopping anyone claim/release/takeover surface.
10. Restored concierge multi-intent, transcription, ambiguity-only confirmation, one-screen aggregate confirmation.
11. Added event template+AI candidate+human confirm.
12. Added nursery candidate/source/AI/diff/source-image/submission/URL/monthly-priority surfaces.
13. Added Google time-change/delete/duplicate decision surfaces.
14. Added Month → DayAgenda and explicit return-state contracts.
15. Added history actual correction and audit-only timestamp.
16. Added terminology view/edit/delete; term learning never changes assignment rules.

## UI coverage groups
- Today / prioritization / daypart: Q1, Q23, Q24, Q35, Q75, Q87
- Task timing / waiting / progress / grouping / bulk: Q21, Q22, Q31, Q54, Q59–Q64
- Request / negotiation: Q36, Q41–Q47
- Share / handover: Q16, Q37–Q40, Q48
- Shopping / anyone: Q33, Q107–Q109
- Event: Q17–Q19
- AI / conversation / terminology: Q70–Q72, Q74, Q76
- Navigation/deep link/assignment agreement: Q78, Q83, Q84
- Nursery: Q89–Q106
- Google: Q110–Q112

## Deliberately not represented as UI
Examples: provider mutation ownership, webhook idempotency, notification deduplication/bundling, stale-write/CAS, household/actor/conversation isolation, test-mode external-side-effect fences. These require source + test evidence and must not be inferred from this HTML.

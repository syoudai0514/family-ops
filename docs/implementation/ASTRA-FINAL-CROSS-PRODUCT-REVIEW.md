# Astra final cross-product review

Review in progress; this record is evidence/history, not product authority.

- Original reviewed HEAD: `9a852b2a89f93f37d91432b6de2c8deebd5fe437`
- Branch: `integration/family-ops-final-candidate`; PR #79
- Base main fresh-read: `06a4e6b1a5aefccb8f9353fad294dd895582bc53`
- Original CI fresh-read: CI #962, Today Navigation #25, Operational Safety #57 succeeded.
- Authority: Accepted ADRs within scope → Requirements Baseline → current design → pinned approved final UX and other non-conflicting supporting design → source/tests.
- Approved UX read at pinned `fec445b9094c535cf79eb6b5ca324998de9ccc67`; the contract is not tracked in the integration branch, as the canonical reference registry explicitly documents.
- No main merge, production mutation/deployment, or F2 execution authorized by this review.

## Purpose and real-use findings

| ID | Severity | Requirement / family impact | Status |
|---|---|---|---|
| XC-01 | HIGH | Q81/83 and §5.5: duplicate partial update passes null owner/time/calendar-end into a replacement-style legacy edit, clearing existing household commitments; explicit owner replacement also bypasses the agreement flow. | Correction authored; DB verification pending. |
| XC-02 | HIGH | Q43/45: the PWA sender has no consultation confirmation control, making the required two-party confirmation impossible there. An unsent locally edited proposal could also confirm the previous saved revision. | Correction authored; component regression 2/2 PASS. |
| XC-03 | BLOCKER | M04/M07/M09/M10/M12: production LINE handlers do not expose required daily negotiation/input/waiting/claim/simulation operations. `入力` and request `その他の返答` redirect to PWA. This is missing implementation, not missing F2 provider evidence. | Uncorrected; continuing review/correction. |
| XC-04 | HIGH | Verification manifest still hard-blocks integration-fixed scenarios using pre-integration `expected-failing` reasons. F2 cannot accept them even with valid final evidence. | Source reconciliation pending; guards must not be weakened. |

## Review progress and remaining work

Requirements Baseline including all Appendix A decisions and pinned final UX
were read. Request, Today, Concierge, Shopping, Nursery, Google, test-mode,
notification, and recovery source boundaries are being traced. No blanket
Requirements/UX PASS is claimed from this interim source inspection.

Current material corrections are deliberately limited to preserving existing
task data and making the existing canonical PWA consultation operation reachable.
No Requirements are changed.

Targeted Web regression: 14/14 PASS (Request consultation + Request deadline
contract + Concierge flow). New SQL regression exercises assigned timed-task
duplicate update, response-loss replay, and assignment-consent rejection.
Full CI/browser evidence on a correction HEAD remains pending.

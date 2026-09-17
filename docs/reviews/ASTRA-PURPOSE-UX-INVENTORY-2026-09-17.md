# ASTRA Purpose-first review — CURRENT inventory / checkpoint ledger
Status: REVIEW / DESIGN / HANDOFF COMPLETE (non-canonical). Artifact date: 2026-09-17.
Repository: syoudai0514/family-ops
Review branch: review/astra-purpose-ux-20260917
Starting anchor and fresh-read reviewed main: 900313187c2460901f91d8aea66051e57729b50b

## Scope and method
Product purpose → present-day household scenarios → canonical requirements/UX → implementation → evidence. This is a source-based independent review, not Physical F2. No production mutation, provider calls, deploy, F2 operations, or main merge is authorized. Implementation is deferred to Sol.

Purpose reconstructed from Baseline §§2–3: externalize the household's prospective memory and coordination; help each adult know the next useful action without making family life a project-management ceremony. LINE is the daily channel, PWA is contextual detail and management, AI proposes/clarifies but never owns consent or authoritative completion. Critical distinction: planned assignment, actual performer, recorder, agreement, acknowledgement, and execution cannot collapse.

## Fresh-read inventory
- GitHub main commit and full tree fetched through GitHub connector. Repository tree includes no AGENTS.md / START-HERE file. Old local checkouts were located but are not used as current evidence.
- Ordinary shell git fetch could not complete; connector reads are pinned to reviewed SHA. Checkpoint commit/push is implemented via GitHub contents API on the dedicated branch.
- Latest merged PRs: #112 future Codmon owner resolution; #111 daily Codmon coordination; #110 Today/shopping simplification and calendar refresh; #108 F2 recovery documentation; #107 holiday fixture; #106 loading/refresh; #105 resumed PWA shell freshness. PR #109 is closed/unmerged temporary integration.
- main CI #1242 (35053420682): SUCCESS; Operational safety #337 (35053420680): SUCCESS.
- Kick LINE UX v5 #76 (35053570223): FAILURE; do not report all workflows green. Operational relevance still to inspect.
- Vercel commit status: success. This does not prove currently deployed DB migration, Edge function versions or physical behavior.
- Production DB application of Q113 remains UNVERIFIED in this review. PR text is historical context, not runtime truth.

## Authority resolution
Read: root README, Baseline, current-design README, ADR index and ADR0012/0013/0014, current design 01/04/10 responsibility/12 Codmon, F2 handoff (2026-09-12).
ADR0012 explicitly makes Baseline the single product/UX authority. ADR0013 governs current detailed design and scope-specific accepted architectural decisions. Product meaning: Baseline → accepted ADR within its explicit scope → current design → non-conflicting v6 → code/tests. Any genuine unresolved top-level contradiction is a stop, not an invitation to select a convenient document.
Current main contains stale lifecycle wording: Baseline header says proposed/pending merge, ADR index says ADR0014 pending, while accepted ADR/current-design index establishes canonical scope. Treat merged path plus explicit scope rules as authority; record metadata drift for repair, never use stale headers to discard the canonical content. Review instructions under current design are audit history, not additional authorities.

## A day to evaluate
| Moment | Family need | Review focus |
|---|---|---|
| 06:30–09:15 | Today's exceptions, handover, childcare preparation, Codmon input/send | What is actionable now; responsibility clarity; readiness; acknowledgement burden |
| Daytime | Capture a thought, shopping need, notice, or request while busy | Classification burden; one natural-language entry; ambiguity only |
| Pickup change | Ask gently, negotiate and know whether agreed | Recipient choice, consent, old owner until acceptance, dependent tasks |
| Shopping / preparation | Avoid duplicate effort; finish without auditing partner | Claim, duplicates, actual units, task/subtask visibility |
| 20:30 | Close the day, record exceptions, prepare tomorrow | One grouped action where meaningful; unknown is not failure |
| Resume/offline | Trust what is shown and recover without re-entering | Freshness, stale/error truth, draft preservation, navigation availability |

## Initial plan at checkpoint 1（以下は履歴、全成果物作成済み）
1. Inspect current implementation across Today / LINE / AI / Request / routine / shopping / nursery / notifications / PWA lifecycle.
2. Record independent review before choosing a solution. Separate proven source defects, UX risk, product proposals and physical unknowns.
3. Push completed material findings, then author PROPOSED detailed design, then copy-ready Sol handoff.
4. Refresh main before final decisions; if changed, assess reviewed-path diff, not historical PR claims.

## Checkpoint log
Checkpoint 1: this inventory and purpose model. Subsequent commit hashes are recorded in later checkpoints; final commit is obtained from branch ref (avoid self-referential SHA).

## Final self-review / checkpoint 8
Completed: independent review → proposed detailed design → copy-ready Sol prompt.
Material findings: **7**. Conforming fixes: **5** (PF-01/02/03/04/07). Product proposals: **2** (PF-05/06). PO-01/02 remain undecided, explicitly excluded from default implementation.
Main was re-read during final preparation and remained `900313187c2460901f91d8aea66051e57729b50b`. Final branch ref must be read after this commit; no self-referential final SHA is embedded.
GitHub compare before final checkpoint showed only the four docs paths below changed. No production source, tests, migration, workflow, canonical requirements/design, or runtime state changed.

### Artifact index
- [Purpose / product / UX review](ASTRA-PURPOSE-UX-REVIEW-2026-09-17.md)
- [PROPOSED detailed design](../proposals/ASTRA-PURPOSE-UX-PROPOSED-DESIGN-2026-09-17.md)
- [Sol copy-ready implementation prompt](../implementation/ASTRA-TO-SOL-IMPLEMENTATION-HANDOFF-2026-09-17.md)
- This inventory is supporting evidence, not a second CURRENT canonical specification.

### Checkpoint commits (in actual creation order)
| Checkpoint | Commit | Content |
|---|---|---|
| 1 | 044f984765d7ba9ade8ca76c7be9fa0a9579b145 | CURRENT inventory and reconstructed purpose |
| 2 | fda347ab0f6c6c3f3a7aeaa6dc57c746a17bb554 | Independent review draft |
| 3 | 6d83ae171fc51277c5d3f687437aa23e34e1ece7 | Six initial material findings and counterexample |
| 4 | bf07723fdf765afc83a8cc67bdd786ecaa8fe7e4 | Proposed product/UX direction |
| 3b | daf0abe6f5935e87ddcac7841ed7a69976a7bc5f | Additional cross-channel semantic finding before detailed API design |
| 5 | b2602341b8f32c8b04e74f44527f6791f085af26 | Detailed design first half |
| 6 | 1f43c4c125af859ffcb6f5836f50e3b2223b39c1 | Complete detailed design, tests and rollout |
| 7 | 51ea1cc08cdc2ef0e220a31cc9d73d02e815b4a7 | Copy-ready Sol handoff |
| 8 | see branch HEAD / commit history | Final consistency and evidence closure |

Every checkpoint was committed directly to the dedicated remote branch via GitHub API, making it durable immediately. Main was never updated.

### Source coverage
Reviewed pinned CURRENT files across:
- governance Baseline/current index/ADR0012–14; scope-relevant accepted ADR0006/0007/0009/0010/0011;
- current architecture/data/state/daily UX/privacy/concurrency/rollout/channel matrix/approved UX/Codmon;
- Today controller, DailyBrief hydration/SQL projection, task checklists, clock/order tests;
- LINE dispatcher, single/multiple intent decomposition, addressee/consultation guard, assignment adapter;
- PWA concierge input/results/confirm/commit/normalization, quick-add/router;
- Request composer/response/consultation, canonical request/group SQL and Edge;
- Shopping, Handovers, Checkin, NurseryReview surfaces;
- notifications sender/quota/expiry, Codmon reminder/seed/guard;
- PWA freshness, HouseholdContext, common Edge client; existing focused tests and CI workflow;
- latest F2 handoff/recovery/Q113 pending record.

This is purposeful sampling, not a claim that every repository line or requirement was audited. No actual browser or provider session was opened.

### Verification evidence
- GitHub CURRENT main CI #1242 / Operational Safety #337: SUCCESS (fresh-read again at final preparation).
- Kick LINE UX v5 #76: FAILURE, preserved as known run state. No rerun or workflow mutation.
- Review branch pre-final HEAD has no Actions runs: CI triggers only main push/PR/manual, no PR created by this review. No full app suite rerun for docs-only output.
- Mocked execution of CURRENT conciergeCommit: PF-02 edited-title/old-message counterexample reproduced; duplicate-existing no-write guard passed. No external mutation.
- Final document validation checks relative document links, finding-ID coverage, approval boundaries, markdown fences, and only-docs remote diff. Product/F2 PASS is explicitly not claimed.

### Self-review decisions
1. Purpose remains family memory/coordination, not technical perfection; seven findings are prioritized by daily burden and trust.
2. Existing strengths preserved: consent, linked Task truth, no scoreboards, group unknown semantics, shared LINE/PWA commands, quotas and privacy.
3. New UX reduces classification and duplicate confirmation; only the PO-gated critical submission proposal adds one explicit tap.
4. AI is used for interpretation/language only, not consent/assignment/readiness/completion.
5. Each material finding has present behavior, Q mapping, concrete UX/state/API/files/migration/tests/F2/rollout, with shared sections for cross-cutting safety.
6. PF-05/06 are not canonicalized. Conforming design is still PROPOSED until normal review/implementation adoption.
7. No production mutation/deploy, main merge, real-wife message, or Physical F2.
8. Important limitation: real daily usability and deployed Q113 state remain unverified. Design is implementation-ready, product is not declared release-ready.

### Next action
Sol reads fresh main and these documents from the review branch, checks whether findings are already fixed, then executes S0–S3 to PR/merge-ready. PO-01/02 can be decided separately without blocking conforming work.

# ASTRA Purpose-first review — CURRENT inventory / checkpoint ledger
Status: REVIEW WORK IN PROGRESS (non-canonical). Artifact date: 2026-09-17.
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

## Next actions at checkpoint 1
1. Inspect current implementation across Today / LINE / AI / Request / routine / shopping / nursery / notifications / PWA lifecycle.
2. Record independent review before choosing a solution. Separate proven source defects, UX risk, product proposals and physical unknowns.
3. Push completed material findings, then author PROPOSED detailed design, then copy-ready Sol handoff.
4. Refresh main before final decisions; if changed, assess reviewed-path diff, not historical PR claims.

## Checkpoint log
Checkpoint 1: this inventory and purpose model. Subsequent commit hashes are recorded in later checkpoints; final commit is obtained from branch ref (avoid self-referential SHA).

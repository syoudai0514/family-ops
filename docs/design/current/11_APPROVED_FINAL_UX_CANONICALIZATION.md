# 11. Approved Final UX — Canonical Reference and Traceability

- **Status:** CANONICAL REFERENCE REGISTRY / no product-meaning change
- **Scope:** CF-10 only; approved UX provenance, discoverability, supersession, and Q traceability
- **Requirements authority:** `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` remains the single requirements/UX Source of Truth
- **Governance:** ADR 0012

## 1. Why this file exists

The approved final UX contract was reviewed on the design prototype branch, while ADR 0012 requires requirements/UX governance to remain unambiguous from the canonical `main` path. Before this registry, an implementer could find several V3/V4/V5/final-looking artifacts and had to know branch history to identify the approved source.

This file closes that governance gap without copying prototype business logic into production and without promoting a prototype above the Requirements Baseline.

## 2. Authority rule

For product requirements and UX meaning:

1. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` is the product requirements/UX authority.
2. Accepted ADRs govern their explicitly accepted architecture/governance scope; ADR 0012 prevents conflicting requirements/UX authorities.
3. `docs/design/current/` is the canonical detailed-design realization when it does not contradict the Baseline.
4. The approved prototype artifacts pinned below are **implementation-facing UI/interaction evidence and specification**, subordinate to the Baseline. They make approved requirements concrete; they do not silently override them.
5. Historical prototype versions are audit/history only and must never be selected because their filename looks newer or more convenient.

If a pinned approved UX clause and the current Baseline ever appear to conflict, stop and resolve the conflict through the canonical requirements/governance process. Do not choose one ad hoc.

## 3. Exact approved source snapshot

Fresh verification for CF-10 resolved the source snapshot as follows:

- repository: `syoudai0514/family-ops`
- source branch: `design/ouchi-concierge-prototype`
- pinned reviewed commit: `fec445b9094c535cf79eb6b5ca324998de9ccc67`
- source tree: `c050676907c16b6d344623a555cd613c4b952e9f`

Tracked contract files at that exact commit:

| Role | Pinned path | Git blob SHA | Status |
|---|---|---|---|
| Final UI / interaction specification | `docs/prototypes/ouchi-concierge/UX-CONTRACT-FINAL-SPEC.md` | `ea579ce2877303292d236db3770a61fece5a2176` | **APPROVED implementation-facing contract**, subordinate to Baseline |
| Final Q trace / audit | `docs/prototypes/ouchi-concierge/UX-CONTRACT-FINAL-AUDIT.md` | `5e6c4bca258c08d8bc5f9f1793e251c9689c46ac` | **APPROVED audit evidence**, 114/114 decision rows mapped |
| Approved post-audit refinements | `docs/prototypes/ouchi-concierge/UX-CONTRACT-APPROVED-DELTAS.md` | `08dad2719f3cedf7f3f757e6a1f02b6b9e68ab8a` | **APPROVED delta evidence**, subordinate to Baseline; concrete transport/Month realization is integrated in current design 09 |
| Prototype branch status/index | `docs/prototypes/ouchi-concierge/README.md` | `faead2e0b1a4e5efff3e0bb826a8fb4cc82d1d93` | Provenance/index only |

### Render hashes

The source documents record two distinct render checkpoints; they are not contradictory:

1. `UX-CONTRACT-FINAL-SPEC.md` / `UX-CONTRACT-FINAL-AUDIT.md` identify the first fully audited final HTML with SHA-256:
   - `42b5a0630d699f969edf14b9b53b0b8bc5fc725c28b5af352a1f9adc050666b4`
2. The prototype branch `README.md` identifies the later user-delivered **no-script iPhone-safe** render after the approved deltas with SHA-256:
   - `c1afa191a8e02f86683e886e0c59a60019b7388531dde19f96de690e8b9e2007`

The tracked, reviewable sources of meaning are the pinned SPEC/AUDIT/APPROVED-DELTAS files above. The render SHA-256 values are provenance anchors for the rendered artifacts; they do not outrank the Baseline or create another canonical path.

## 4. Approved delta integration status

`UX-CONTRACT-APPROVED-DELTAS.md` records five post-audit refinements:

1. compact transport token on narrow calendar surfaces: `送P迎M` / `送P` / `迎M`;
2. Month date selection shows inline day summary before full detail;
3. regular transport is one weekly template per validity period, default end indefinite;
4. inserting a later template auto-closes the preceding open-ended template on the previous day;
5. a day/occurrence override remains separate from the period template.

These are already represented in canonical detailed design at:

`docs/design/current/09_TRANSPORT_PERIOD_TEMPLATE_AND_MONTH_UX.md`

Design 09 remains subordinate to the Requirements Baseline and explicitly preserves rule-derived-future-only recalculation, protected individual agreements/overrides, structured assignment data, and the shared LINE/PWA product model.

## 5. Material UX clause → Q mapping

The final audit already proves literal 114/114 mapping of Q1-Q112 plus Q60-1/Q60-2. The table below is the **main-governance material-clause index** so an implementer can navigate from the approved final UX contract back to canonical decisions without treating the prototype as a second requirements document.

| Approved final UX material clause | Canonical Q / Baseline trace |
|---|---|
| Product loop: understand current situation → go to action → understand parent/subtasks → complete now → evening reconciliation → exceptions deeper | Q1, Q23-Q24, Q59-Q64, Q75, Q87; Baseline §§2-3, 10-14 |
| Today first viewport, actionable summary/direct jumps, runtime morning/day/evening, own-work priority and partner summary | Q1, Q23-Q25, Q35, Q67-Q68, Q75, Q87-Q88; Baseline §§13-14 |
| Parent task/subtask progress; no generic partial-complete button; bulk scope excludes `余力があれば` | Q54, Q59-Q61, Q60-1/Q60-2; Baseline §§9.3, 10 |
| Immediate actual + evening reconciliation; `全部/大体/個別`; unknown child semantics; correction/undo; original target date | Q5-Q7, Q29, Q31, Q59-Q66; Baseline §§10-11 |
| Back/deep-link/return-state semantics and no full reload/scroll-to-top after one item update | Q78-Q79 plus Baseline UX principle 8, §15 and §23 concurrency expectations |
| Task optional date/time fields, waiting, carryover, reschedule, early work, validity-period rules and protected future occurrences | Q12-Q15, Q21-Q22, Q31, Q50-Q57; Baseline §§6, 9 |
| Request / assignment lifecycle; first response tier; checking vs consulting; expiry/reproposal; request-vs-linked-ToDo truth; external agreement correction; separate reply/work deadlines | Q2, Q9, Q30, Q36, Q41-Q47, Q69, Q83-Q85; Baseline §7 |
| Share/handover scope, validity, acknowledgement, notification and correction history | Q3, Q16, Q37-Q40, Q48-Q49; Baseline §8 |
| Shopping action-level actual and formal `誰でもOK` claim/release/takeover | Q33, Q107-Q109; Baseline §§6.5, 12 |
| Event template + AI candidates + human review; no event-wide coordinator; milestone/risk notification | Q17-Q19, Q58; Baseline §17 |
| Concierge / universal input: transcription-first, multi-intent decomposition, ambiguity-only clarification, terminology semantics, duplicate choices | Q8, Q70-Q74, Q81; Baseline §§13, 16 |
| LINE fixed menu, `今日`, context-aware `入力`, free-text `追加`, image triage, exact PWA deep link, no PWA self-success echo | Q4, Q25-Q26, Q35, Q65-Q80, Q87-Q88, Q96; Baseline §§13-15, 19.2 |
| Nursery image grouping/inference/review/provenance/privacy/update/monthly/recurrence/exception/submission/URL/evidence | Q89-Q106; Baseline §19 |
| Google schedule-first boundary, change/delete/duplicate handling and shared protected-value Authority model | Q34, Q95, Q110-Q112 plus Baseline §§5.5, 18 |
| Operational Loading/Empty/Error/Stale states and stale/concurrent safe resolution | Baseline UX principles 6-8 and §23; final audit correctly classifies runtime/source proof separately from UI evidence |
| One-user test mode, history/analysis, correction, deletion-vs-outcome semantics | Q20, Q27-Q29, Q62-Q63, Q82; Baseline §§20-22 |
| Approved post-audit transport/Month refinements | Q10-Q12, Q34, Q50-Q52, Q78 plus Baseline §§6, 15, 18; concrete non-conflicting realization in design 09 |

For literal decision text, always read Appendix A in the current Baseline. Do not copy this mapping into a competing requirements list.

## 6. Historical / superseded prototype artifacts

At the pinned approved prototype commit, the prototype README explicitly states that older prototype assets and versioned documents are historical and must not override the final spec/audit, approved deltas, or canonical requirements.

The following are therefore **HISTORICAL / SUPERSEDED FOR CURRENT UX IMPLEMENTATION**:

- `docs/prototypes/ouchi-concierge/UX-CONTRACT-V3.md`
- `docs/prototypes/ouchi-concierge/UX-CONTRACT-V4.md`
- `docs/prototypes/ouchi-concierge/UX-CONTRACT-V5.html`
- `docs/prototypes/ouchi-concierge/UX-CONTRACT-V5-AUDIT.md`
- older prototype `index.html`, `prototype.css`, and `prototype.js` assets referenced by the pinned prototype README

Rules:

- keep them for Git/history/audit evidence;
- do not cite them as CURRENT UX authority;
- do not merge a clause from them because it is easier to implement;
- do not use `V3`, `V4`, `V5`, `FINAL`, or `LATEST` naming as an authority heuristic;
- navigate from the canonical Requirements/design indexes and this registry instead.

## 7. Canonical navigation for implementers/reviewers

Start in this order:

1. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
2. `docs/adr/0012-requirements-ux-canonical-governance.md`
3. `docs/design/current/README.md`
4. relevant current design file(s), including `10_LINE_PWA_RESPONSIBILITY_MATRIX.md` for channel responsibility after product-owner approval
5. this registry for the exact approved UX snapshot and Q mapping
6. pinned SPEC/AUDIT/APPROVED-DELTAS source when screen wording, interaction hierarchy, state disclosure, or trace evidence is needed
7. CURRENT source/tests/runtime — which must conform to the authorities above and never silently redefine them

## 8. Scope statement

This canonicalization changes **governance/discoverability only**. It does not:

- change Request behavior;
- change Concierge behavior;
- change Today behavior;
- add a new command/state/business truth;
- change notification semantics;
- change provider mutation ownership;
- make prototype fixture chores/dates/assignees into product defaults;
- merge anything to `main` by itself.

Any future product-meaning change still requires an explicit Baseline update under ADR 0012.

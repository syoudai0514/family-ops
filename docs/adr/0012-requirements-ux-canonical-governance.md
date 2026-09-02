# 0012. Establish the Requirements & UX Baseline as the normative product source

## Status

Accepted — PR #39 merged after fresh independent re-review returned `GO` on 2026-09-02.

## Context

ADR 0001 committed the repository to `docs/design/v6/` as the single normative design source for the implementation and explicitly prohibited silent product-scope drift.

PR #39 introduces a deliberate product-direction revision after a new requirements/UX elicitation cycle. The new canonical document is:

`docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`

An independent review of PR #39 identified a governance blocker: if the Baseline claims to be the requirements/UX Source of Truth while ADR 0001 still claims `docs/design/v6/` is the sole normative source for all following work packages, two valid-looking sources can disagree and different implementers can choose different truths.

This ADR resolves that conflict explicitly rather than letting a README or implementation PR silently supersede an Accepted ADR.

## Decision

From the merge of ADR 0012 and PR #39:

1. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` is the **single normative source for product requirements and UX behavior**.
2. ADR 0001 and `docs/design/v6/` remain normative for **architecture, implementation constraints, security, API/Edge Function contracts, and other design decisions that do not conflict with the current Requirements & UX Baseline**.
3. Where the current Requirements & UX Baseline and `docs/design/v6/` conflict on product behavior, user flow, state semantics, notification policy, assignment semantics, evidence semantics, or other requirements/UX matters, the Baseline wins.
4. An implementation may not choose between the Baseline and v6 ad hoc. A conflict that reaches architecture/API/schema/security must be resolved explicitly through a new or amended ADR and, where needed, detailed design updates before implementation.
5. `docs/design/v6/` remains vendored/read-only historical design material. This ADR does **not** create an implicit v7 package and does not rewrite v6 in place.
6. New requirements/UX decisions are not final merely because they appear in chat, issues, or PR comments. They become normative only after they are integrated into the canonical Baseline path and merged to `main`.
7. If a future ADR deliberately supersedes a requirement in the Baseline, it must state that scope explicitly and the Baseline must be updated in the same or a preceding docs change so that the canonical file remains current.
8. Existing ADRs 0002+ remain valid unless they conflict with the current Baseline or a later ADR explicitly supersedes them.

## Relationship to ADR 0001

ADR 0001 is **superseded in part**:

- its prohibition on silent design drift remains in force;
- its requirement that implementation follow a single clear normative source remains in force;
- its statement that `docs/design/v6/` is the sole normative source for all future product behavior is scope-limited by this ADR.

The resulting hierarchy is:

1. current accepted ADRs that explicitly govern the decision in question;
2. current `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` for requirements/UX;
3. `docs/design/v6/` for non-conflicting legacy architecture/implementation design;
4. implementation/code/tests, which must conform to the above rather than silently defining new product behavior.

If two items at the top of this hierarchy appear to conflict, the conflict must be resolved explicitly before implementation proceeds.

## Consequences

- Reviewers and implementers have one clear requirements/UX source while retaining useful v6 architecture and implementation assets.
- The repository does not need a full v7 rewrite merely to adopt the new household-operations requirements.
- Existing v6-based implementation can be extended where compatible rather than replaced wholesale.
- Future requirement changes must keep the Baseline current and use ADRs when they change architectural or previously accepted design commitments.
- PR #39 passed the independent merge gate with `GO`; the canonical Baseline is now active on `main`.

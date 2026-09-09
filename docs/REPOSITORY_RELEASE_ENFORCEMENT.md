# Repository / Production Release Enforcement

This is the operational contract for CF-15. It complements the canonical
requirement that normal implementation work does **not** push directly to
`main` (`docs/design/current/07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`). It does
not change application behavior.

## Production branch invariant

- Vercel production Git branch remains `main`.
- A successful, reviewed merge to `main` is therefore the normal production
  deployment trigger.
- Do **not** re-enable feature-branch or pull-request Preview deployments as
  part of repository protection. Preview suppression and main protection are
  separate controls.

## Required normal path to main

For ordinary development, `main` must be protected so an unreviewed/direct
update cannot bypass release-critical checks.

Preferred GitHub repository branch ruleset targeting the default branch
`main`:

1. enforcement status: **Active**;
2. **Require a pull request before merging**;
3. **Require status checks to pass before merging**;
4. use strict/up-to-date status checks when practical;
5. **Block force pushes**;
6. **Restrict deletions** / do not allow branch deletion;
7. do not configure a routine bypass path.

Required check contexts for the current repository are:

- `web (lint / typecheck / test / build)`
- `db (migrations / RLS / RPC / idempotency / quota)`
- `edge-functions (deno lint / check / auth-matrix lint)`
- `supabase-integration (real CLI stack)`
- `operational-safety (backup controls)`

These names are the GitHub Actions **job names**, not workflow display names.
If any job is renamed, this document and the repository ruleset must be
updated in the same change so required-check enforcement does not silently
become stale.

### Review count

The mechanical requirement is that the normal path is a pull request and
cannot merge while release checks fail. Human approval count depends on the
maintainer topology:

- owner-only repository: PR required, approval count may be 0 to avoid a
  self-approval deadlock;
- repository with an independent maintainer/reviewer: require at least 1
  approval.

Do not disable PR or status-check requirements merely because approval count
is zero.

## Why production smoke is not a pre-merge required check

`main` is itself the production deployment trigger. A smoke check that can
only run against the newly deployed production release cannot be required
*before* that same merge without creating a circular gate.

Therefore:

- Web / DB / Edge / integration / operational-control checks are pre-merge
  repository gates.
- Production smoke is a separate post-deployment release-health signal and
  must be reported separately.
- If a future architecture introduces a pre-production deployment that can
  run a true production-equivalent smoke before merge, the canonical release
  design may add it as a required check at that time.

## Break-glass

Break-glass is for a genuine production incident only; it is not an ordinary
shortcut around checks.

The steady-state ruleset should have **no configured bypass actors**. If an
administrator must temporarily relax the `main` rule for a genuine incident:

1. record the incident/reason before the update when feasible;
2. record the exact commit SHA being placed on `main`;
3. run the release-critical checks against that exact SHA;
4. make the smallest emergency change possible;
5. restore the normal `main` protection immediately after the emergency
   update;
6. open/follow with a normal PR that reconciles the emergency change and its
   documentation/tests;
7. record which checks and production smoke were performed.

Do not enable force pushes for break-glass. Prefer a temporary, auditable
administrator rule change over a standing bypass actor or rewriting `main`
history.

## Verification — CF-15 is not PASS from YAML/docs alone

After configuring GitHub, fresh-read the repository rule state and verify:

- `main` is protected / targeted by an Active ruleset;
- pull request is required for the normal path;
- all five required status checks above are enforced;
- force pushes are blocked;
- deletion is blocked;
- no configured bypass actor makes the rule ineffective.

The repository includes a read-only verifier for that effective state:

```bash
GITHUB_REPOSITORY=syoudai0514/family-ops \
  bash scripts/verify_repository_enforcement.sh
```

`GH_TOKEN` or `GITHUB_TOKEN` may be supplied to avoid unauthenticated GitHub
API rate limits. The verifier never writes repository settings and never
prints token values. It reads the target branch plus active branch-ruleset
details and fails unless the PR rule, all five release-critical contexts,
`non_fast_forward`, `deletion`, and zero bypass actors are evidenced.

Its fixture regression suite is
`tests/operations/repository_enforcement_test.sh` and runs inside the existing
`operational-safety (backup controls)` required-check candidate. Keeping the
job name unchanged prevents this additional verifier coverage from silently
changing the required GitHub check context.

CF-15 is PASS only when the effective GitHub state is demonstrated. A CI
workflow that merely runs *after* a direct push is not an equivalent
preventive control.

## Current tooling limitation for applying repository settings

The ChatGPT GitHub connector used for this lane can read repository branch,
ruleset and workflow state and can create branches/files/PRs, but it does not
expose an administration write action for branch protection/rulesets. It also
does not expose GitHub Actions secret mutation. This is a connector
capability limitation, not evidence of a GitHub account-plan limitation.

When that limitation applies, perform all repository-side code/CI/docs work,
then make the smallest manual GitHub admin change described below and
fresh-read the effective state afterward before declaring CF-15 PASS.

### Smallest manual GitHub admin action

In repository **Settings → Rules → Rulesets**, create a branch ruleset for
`main` (or use the equivalent protected-branch UI if rulesets are not
available):

- target: default branch / `main`;
- enforcement: Active;
- require pull request before merging;
- require the five check contexts listed above;
- require branch up to date before merging when practical;
- block force pushes;
- block deletion;
- configure **no bypass actors**. For genuine break-glass, use the temporary,
  audited administrator procedure above instead of leaving a standing bypass.

After saving, re-read GitHub and run the verifier above. Do not assume the form
submission succeeded merely because the settings page accepted it.

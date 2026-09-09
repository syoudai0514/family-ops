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

The preferred mechanism is an **Active GitHub branch ruleset** targeting the
default branch `main`. A classic branch-protection rule is also acceptable if
it independently provides the same preventive strength.

For a branch ruleset require:

1. enforcement status: **Active**;
2. **Require a pull request before merging**;
3. **Require status checks to pass before merging**;
4. use strict/up-to-date status checks when practical;
5. **Block force pushes** (`non_fast_forward`);
6. **Restrict deletions** (`deletion`);
7. no configured standing bypass actors.

For classic branch protection require:

1. pull requests before merging;
2. the same required status checks below;
3. **Include administrators / enforce for administrators**;
4. force pushes disabled;
5. branch deletion disabled;
6. no pull-request bypass allowances.

Required check contexts for either mechanism are:

- `web (lint / typecheck / test / build)`
- `db (migrations / RLS / RPC / idempotency / quota)`
- `edge-functions (deno lint / check / auth-matrix lint)`
- `supabase-integration (real CLI stack)`
- `operational-safety (backup controls)`

These names are the GitHub Actions **job names**, not workflow display names.
If any job is renamed, this document and the repository protection must be
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

Steady state must have no configured ruleset bypass actors and no classic
branch-protection PR bypass allowances. If an administrator must temporarily
relax the `main` rule for a genuine incident:

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
administrator rule change over a standing bypass or rewriting `main` history.

## Verification — CF-15 is not PASS from YAML/docs alone

After configuring GitHub, fresh-read the effective repository state and
verify one complete preventive mechanism:

- `main` reports protected;
- normal updates require a pull request;
- all five required status checks above are enforced;
- force pushes are blocked;
- deletion is blocked;
- the mechanism has no normal standing bypass path.

The repository includes a read-only verifier:

```bash
GITHUB_REPOSITORY=syoudai0514/family-ops \
GH_TOKEN='<admin-capable token supplied outside logs/chat>' \
  bash scripts/verify_repository_enforcement.sh
```

The verifier accepts either of the two complete mechanisms above; it does not
weaken requirements by combining incomplete controls into a synthetic PASS.

For rulesets, GitHub can omit `bypass_actors` when the caller lacks sufficient
ruleset visibility. Interpreting an omitted field as an empty bypass list
would be a false PASS, so ruleset verification is **fail-closed** unless
`bypass_actors` is actually visible and empty.

For classic branch protection, the verifier requires admin-readable branch
protection detail and specifically checks PR requirement, all five status
checks, `enforce_admins=true`, force-push disabled, deletion disabled, and no
PR bypass allowances.

The verifier never writes repository settings and never prints token values.
It sends the current GitHub REST API version header (`2026-03-10`). Its
fixture regression suite is
`tests/operations/repository_enforcement_test.sh` and runs inside the existing
`operational-safety (backup controls)` required-check candidate. Keeping that
job name unchanged prevents the additional coverage from silently changing
the required GitHub check context.

CF-15 is PASS only when effective GitHub state is demonstrated. A CI workflow
that merely runs *after* a direct push is not an equivalent preventive
control.

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

Preferred: repository **Settings → Rules → Rulesets**, create an Active branch
ruleset for default branch / `main` with PR required, the five checks above,
force-push prevention, deletion prevention, and no bypass actors.

Equivalent fallback: configure classic branch protection for `main` with PR
required, the five checks above, administrator enforcement enabled, force
push disabled, deletion disabled, and no PR bypass allowances.

After saving, re-read GitHub and run the verifier above with sufficient
visibility. Do not assume the settings-page submission succeeded merely
because the UI accepted it.

# Issue #54 — Gate C real iPhone user acceptance evidence

Status: **POST-PRODUCTION ACCEPTANCE PENDING / NOT YET EXECUTED**.

The previous equivalent-device evidence was correctly rejected: mobile CSS, jsdom/component tests, CI, and source inspection are not real-iPhone acceptance.

By explicit user release decision on 2026-09-07, physical Gate C is now sequenced **after production deployment**. It is therefore not a blocker to merging/deploying PR #56, but it remains mandatory production acceptance evidence after release.

Separately, LINE/PWA Concierge service-level parity is a **user-approved deferred gap** owned by Issue #58 and is not part of PR #56 Gate C/release blocking scope. This defer does not withdraw that requirement.

## Production acceptance sequence

1. Merge the CI-green PR #56 to `main` after final release checks.
2. Apply required production Supabase migrations / Edge changes.
3. Confirm Vercel Production is serving the merged `main` SHA.
4. Run the real-iPhone scenarios below against production.
5. Record exact production/main SHA, deployment identity, device/browser/PWA mode, and each observation here.
6. If a Gate C defect is found, fix only that release defect; do not mix Issue #58 Concierge parity work into the release fix.

## Safety constraints during physical acceptance

- Avoid real LINE sends/provider mutation unless a scenario explicitly requires and separately authorizes it.
- Avoid Google provider mutation; review/read-only surfaces are sufficient for the listed safe checks.
- Prefer test/simulation paths for mutation-sensitive scenarios where available.
- Do not treat Issue #58 cross-channel service-level parity as a PR #56 acceptance failure.

## Required real-iPhone production scenarios

| Scenario | Required physical interaction and acceptance evidence |
|---|---|
| Today first viewport | Open Today on production iPhone PWA. Confirm `最初にここだけ見ればOK` and the four meaning labels (`返事・担当未定`, `今日の自分タスク`, `待ち・あとで確認`, `明日の予定・準備`) are readable. Tap relevant shortcuts and verify navigation/scroll target. |
| Check-in bulk scope | Open an active/safe check-in. Immediately above `全部やった`, verify concrete included names and optional/excluded names are visibly separated. Avoid unnecessary external-provider mutation. |
| Concierge PWA basic behavior | Check the PR #56 PWA Concierge behavior that is part of this release. **Do not use LINE/PWA service-level equivalence as the acceptance criterion; that work is deferred to Issue #58.** |
| Results edit | Tap `編集`, change a candidate field, save it, and verify the edited candidate proceeds to confirmation. |
| Back/state | Return/back through exercised flows and verify draft/filter/selection/scroll state preservation where specified. |
| Existing safe high-risk paths | Spot-check Requests, History correction, Month/day agenda, LINE reference deep-link, and Google/Nursery review surfaces without real LINE/Google provider mutation. |

## Deterministic support evidence

These checks support the production acceptance but do not replace the physical iPhone run:

- CI #719 on `8b66598cd942cb4cdc5dfcd2eb7624e46b8bf51f` — FULL GREEN;
- CI #720 on `2e2782a27e6bf448b5d3c167a00754927e0ab008` — FULL GREEN;
- CI #722 on `8e12047354c1f2ed47561f022534b58bdb070e3c` — FULL GREEN;
- Web lint/typecheck/test/build;
- Edge lint/typecheck/unit/auth-matrix;
- DB migrations/regression suite;
- real Supabase CLI stack;
- Q1–Q112/canonical/RLS/CAS/idempotency/provider-fence regression.

## Recording rule after production

Record:

1. exact production/main SHA;
2. Vercel production deployment ID/URL;
3. date/time and iPhone/browser/PWA mode;
4. each scenario PASS/FAIL with visible result;
5. failure reproduction steps if any;
6. confirmation that no unnecessary LINE/Google provider mutation occurred.

Until recorded, **post-production Gate C remains pending**, but this pending state no longer blocks the explicitly authorized PR #56 production release.

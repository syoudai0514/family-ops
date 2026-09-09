# CF-11 Right-size implementation note

This note records why the Requirements Baseline itself is not rewritten by ADR 0014.

Fresh review of `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` confirmed that the canonical Baseline:

- defines household product/UX intent and the two-person initial household context;
- deliberately does not pin implementation technology for non-functional concerns;
- contains no requirement naming Cloudflare R2, age, an owner-local backup key, or a specific backup provider;
- delegates conflicting architecture/security mechanics to explicit ADR/current detailed-design evolution under ADR 0012/0013.

The Product Owner's 2026-09-09 decision changes the **architecture/operational means** of satisfying recoverability, not ordinary user-facing product behavior. Therefore the branch proposes ADR 0014 + `10_BACKUP_RECOVERY.md` to supersede legacy v6 mechanics without creating a second Requirements Baseline or editing v6 history.

Under ADR 0012, this is **Product Owner approved / pending canonical merge**. It does not become Accepted/canonical, and does not formally supersede v6 WP10, until the reviewed change is merged to protected `main`.

The approved recovery objective and its operational acceptance—including isolated app-save-hub namespace, actual backup/read-back/freshness, disposable restore, new-Auth UUID rebinding and authenticated household access—are defined in ADR 0014 and `10_BACKUP_RECOVERY.md`.

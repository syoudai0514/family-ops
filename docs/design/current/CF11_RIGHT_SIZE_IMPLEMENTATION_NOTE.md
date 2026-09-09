# CF-11 Right-size implementation note

This short implementation note records why the Requirements Baseline itself is
not rewritten by ADR 0014.

Fresh review of `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
confirmed that the canonical Baseline:

- defines household product/UX intent and the two-person initial household
  context;
- deliberately does not pin implementation technology for non-functional
  concerns;
- contains no requirement naming Cloudflare R2, age, an owner-local backup key,
  or a specific backup provider;
- delegates conflicting architecture/security mechanics to explicit ADR/current
  detailed-design evolution under ADR 0012/0013.

The Product Owner's 2026-09-09 decision changes the **architecture/operational
means** of satisfying recoverability, not ordinary user-facing product behavior.
Therefore ADR 0014 + `10_BACKUP_RECOVERY.md` explicitly supersede the legacy v6
mechanics without inventing a second Requirements Baseline or silently editing
v6 history.

The accepted recovery objective for CF-11 is recorded verbatim in ADR 0014 and
its operational acceptance is defined in `10_BACKUP_RECOVERY.md`.

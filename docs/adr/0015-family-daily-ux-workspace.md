# ADR 0015: Human-confirmed family setup and assignment preview

Status: Proposed; implementation branch, pending review and protected merge.

## Context

Families cannot edit child/school context in the app or recover lost invitations. Assignment requests currently ask for acceptance before showing all affected work. The user explicitly authorized a user-focused improvement pass and clarified that AI should help people coordinate without escalating arguments.

## Decision

Add one authenticated `family-setup` Edge endpoint with `verify_jwt=true` and `requireUserActor`. The actor comes from validated authentication, never the request body. The endpoint supports:

| Action               | Meaning                                                          | Database entry point             |
| -------------------- | ---------------------------------------------------------------- | -------------------------------- |
| `read`               | Household children, school periods, member LINE linkage status   | `server_read_family_setup`       |
| `assignment_preview` | Exact saved request targets and eligible transport-linked chores | `server_read_assignment_preview` |
| `save_context`       | Human-confirmed child/school-period create or update             | `server_tx_family_setup`         |
| `finish_later`       | Mark setup steps deferred so the family can start                | `server_tx_family_setup`         |
| `reissue_invite`     | Expire unused links and generate a new invite after confirmation | `server_tx_family_setup`         |

Read functions validate household membership, are service-role-only, and use an empty search path. Browser roles cannot call them with another actor ID. Existing authenticated `get_my_daily_brief` retains its identity and capability checks and adds only task IDs classified as special weekdays.

Writes use the existing private mutation-receipt pattern and a household lock. Child IDs and school context IDs must belong to the actor's household. Deferring setup changes no capability gates, task data, or provider sends. The invite recovery receipt excludes raw tokens; a replay asks for explicit recovery rather than exposing the token again.

Assignment previews derive from saved terms, reject stale revision snapshots, and apply the same protected override/event/claim rules as canonical transport reconciliation. The final accept command still performs its canonical checks; a preview never changes assignments.

AI consultation uses the existing private draft endpoint. A human reviews and sends the resulting proposal. Existing two-party confirmation semantics remain required. No new provider or automatic AI decision path is introduced.

The frozen v6 52-endpoint auth matrix remains unchanged. The live matrix explicitly includes `family-setup` in the authenticated gap-fill allowlist, alongside earlier extensions.

## Consequences

Deploy the migration and new endpoint together before enabling the changed UI. All previous notification, calendar writer, and one-person simulation activation gates remain in force. Local SQL and mocked browser verification cannot prove email, real LINE delivery, or physical device behavior; those remain release verification work.

# ASTRA PARTIAL HANDOFF — final cross-product review

This is review evidence/history, not replacement product authority. F2-ready: **NO**.
A partial handoff is intentional: two uncorrected material product findings remain;
no blanket Q1–Q112 or whole-product PASS is claimed from technical CI.

## Target and authority

- Original reviewed HEAD: `9a852b2a89f93f37d91432b6de2c8deebd5fe437`
- Branch: `integration/family-ops-final-candidate`; existing Draft PR #79
- Fresh-read base main: `06a4e6b1a5aefccb8f9353fad294dd895582bc53`
- Resume fresh-read confirmed the original branch head and recovered seven local changed files.
- Accepted ADRs within scope → Requirements Baseline → current design → non-conflicting supporting design → implementation/tests.
- Baseline including Appendix Q1–Q112 was read. Reading is not an individual-requirement verification verdict.
- Approved final UX read at registry-pinned `fec445b9094c535cf79eb6b5ca324998de9ccc67`, path `docs/prototypes/ouchi-concierge/UX-CONTRACT-FINAL-SPEC.md`. Its absence from the integration checkout is explicitly explained by the registry.
- PR #73 actually merged ADR0014 to main at the base SHA above, 2026-09-09 11:01:58Z. The old PR body and old pending-status assertions are history.

## Review completion and outcome

| Review | Completion | Outcome / limit |
|---|---|---|
| Purpose | Complete for readiness decision | PARTIAL: Today and canonical task execution are useful, but ordinary LINE work still requires channel switching and consultation can promise unapplied work changes. |
| Requirements | Incomplete | Material paths traced; no complete per-Q entry-point closure. XC-03 and XC-05 contradict required normal use. |
| UX / real use | Incomplete | Actual PWA sender confirmation fixed and browser-tested; full morning→day→evening→next-day family flow remains incomplete. |
| Cross-product | Incomplete | Request, Today, Concierge, Shopping, Nursery, Google and recovery boundaries inspected; remaining cases below still need closure. |
| Verification / F2 readiness | Complete for NO decision | Known source defects are separated from genuine external-provider/device pending evidence. F2 must not start as a final acceptance run yet. |

## Material findings

| ID | Severity | Finding | Disposition |
|---|---|---|---|
| XC-01 | HIGH | Concierge `既存を更新` passed omitted owner/time/calendar-end as null into a replacement-style legacy edit, erasing existing commitments; a changed owner could bypass the agreement path. | Fixed. Assigned/timed task preservation, receipt replay and consent rejection covered by SQL85; DB suite PASS. |
| XC-02 | HIGH | PWA request sender had no consultation confirmation control. Locally edited, unsubmitted text could also confirm a different saved revision. | Fixed. Both parties can reach the existing command, unsent edits disable confirmation, and refresh preserves surrounding state. Component tests and actual-route Chrome evidence PASS. |
| XC-03 | BLOCKER | Approved M04/M07/M09/M10/M12 require daily LINE completion, but production LINE has no normal consultation/mostly-done+undo/waiting/claim-release/simulation entry. `入力` and request `その他の返答` hand off to PWA. | Unfixed. Missing implementation, not F2 provider evidence. Detailed source/reproduction below. |
| XC-04 | HIGH | Executable F2 manifest retained stale pre-integration product-failure reasons; valid later evidence could never pass those scenarios. | Fixed classification. Integrated Shopping/Today and genuinely external input/provider evidence now use external-pending. Actual LINE defects remain expected-failing; whole-day remains skeleton. Assessor guards are unchanged and still tested. |
| CF-SOL-01 | MEDIUM, material governance | Root README called v6 canonical; merged ADR0014 and current recovery design still claimed pending canonical merge. Offline governance regression required those stale statements. | Independently confirmed against PR #73; README, ADR, current design and governance assertions corrected together. No product Requirement change. |
| XC-05 | HIGH | Free-text consultation suggests swaps/reschedules but does not represent/apply the negotiated Task changes. Two confirmations accept the original structured assignment snapshot; light-request Task creation reads original request fields. | Unfixed. Lane A's own bounded-follow-up note confirms the missing structured semantics. Not a license to silently reinterpret free text or weaken the approved UX. |
| XC-06 | HIGH, operational | A documentation-only Draft PR update automatically ran a workflow that writes a persistent recovery generation to app-save-hub. | Draft-run guard added and tested; later run #14 SKIPPED. The earlier write actually happened; incident and remaining operational limits below. |

## Implemented corrections / files

1. XC-01: `supabase/migrations/20260909231217_astra_material_cross_product_corrections.sql`, `supabase/functions/_shared/errors.ts`, `tests/sql/85_astra_duplicate_preservation.sql`.
   - **One additional migration**, no production application.
   - Omitted owner/work-time/calendar-end preserved; date-only change keeps local times; explicit owner replacement requires existing agreement flow.
   - Receipt-before-CAS ordering retained; conflict never falls through to create.
2. XC-02: `apps/web/src/features/requests/Requests.tsx`, `Requests.consultation.test.tsx`, `docs/design/current/03_STATE_MACHINES_AND_COMMANDS.md`.
3. CF-SOL-01/XC-06: `README.md`, `docs/adr/0014-right-sized-household-backup-recovery.md`, `docs/design/current/10_BACKUP_RECOVERY.md`, `tests/operations/backup_controls_test.sh`, `.github/workflows/recovery-drill.yml`.
4. XC-04/evidence: `tests/evidence/cf14/scenarios.mjs`, `cf14-authoring.test.mjs`, `docs/implementation/CF14-REQUIREMENT-EVIDENCE-MATRIX.md`, `scripts/run_cf14_browser_e2e.mjs`, `run_cf14_browser_e2e_ci.mjs`, `run_today_navigation_browser_e2e.mjs`, `.github/workflows/ci.yml`, `.github/workflows/today-navigation-evidence.yml`.
   - Chrome pipes are drained; bounded startup diagnostics retained, no false PASS on browser failure.
   - Added a sixth real-browser scenario: authenticated Requests route, sender's unsent edit blocked, saved terms confirmed with exact revisions, canonical refresh changes bucket.
   - Screenshots from the first successful hosted run lacked Japanese fonts. CI now installs Noto CJK and captures the actual consultation controls before confirmation; DOM/HTTP assertions remain mandatory.

## XC-03: reproducible entry-point mismatch and next correction

Authority: `docs/design/current/10_LINE_PWA_RESPONSIBILITY_MATRIX.md` explicitly prohibits replacing a LINE MUST complete row with “LINE starts, PWA finishes”.

| User action | Actual source | Required next implementation / verification |
|---|---|---|
| Send `入力` | `process-line-inbox/index.ts`, `tryHandleReadOnlyText`, input branch sends `/today?entry=checkin` only | Present actual canonical sessions; expose all/mostly/individual and undo via the same reconciliation RPCs used by PWA. Verify webhook→command→canonical readback. |
| Request `その他の返答` | `send-notifications/index.ts`, `buildRichRequestMessage` creates `/requests?...&response=other`; shared Flex builder emits URI. | LINE checking/consultation/terms confirmation/expiry/reproposal routes with observed attempt and terms revisions. Do not auto-upgrade stale ID-only replies to current consent. |
| See both deadlines | Assignment Flex has reply/work fields; general request Flex receives only `scheduleLabel` from work `due_at` | Show the persisted attempt reply deadline separately for light requests too. Verify exact text and command expiry behavior. |
| Wait / resume / next-check | No `server_tx_set_task_waiting` dispatch in production LINE worker | Add discoverable normal LINE actions using existing canonical task revision and waiting command. |
| Claim / release `誰でもOK` | No `server_tx_shopping_claim_v2` dispatch in production LINE worker | Add claim/release from current item state, retain no automatic expiry and no assignment rewrite. |
| One-user simulation | PWA `test-simulation` Edge and RPCs exist; no corresponding LINE dispatch | Add explicit synthetic-mode entry and role actions; keep provider/real-spouse side effects fenced. Q27 must start at webhook/postback, not a fabricated workspace JSON. |

The existing LINE worker still has useful accept/decline, per-item routine and legacy complete-all actions. The finding is about the missing required lifecycle, not claiming that LINE has no functionality at all. M13–M18 explicitly permitted rich/rare PWA handoffs remain valid.

## XC-05: evidence and bounded next step

`Requests.tsx` `ConsultationTerms` submits only `terms.candidate` text and displays
an example like “明日は私、金曜は交代”. The latest canonical transition in
`20260909043000_lane_a_explicit_terms_confirmation.sql` forbids changing
`assignment_targets`/`due_at` for assignment requests. After confirmation it calls
`fn_apply_request_assignment_v1` against the unchanged server snapshot; light
requests call `fn_ensure_light_request_task_v1` with the request ID rather than a
negotiated Task patch. `LANE-A-REQUEST-CANONICALIZATION.md` “bounded follow-up”
explicitly acknowledges that structured swap/reschedule semantics are absent.

Reproduction: propose different time/swap in the displayed terms input, save it,
then have both parties confirm. The lifecycle reaches accepted while the work
mutation still follows the original structured fields. XC-02 makes the sender
control reachable; it does not claim to fix this separate execution mismatch.

Next owner should represent approved material terms as explicit structured
canonical patches and show their concrete effect before both confirmations;
then test the changed Today/Task result, stale task conflicts and LINE/PWA parity.
Do not silently parse arbitrary agreed prose into mutations. If the Product
Owner wants to reduce the existing approved behavior, that is a separate decision;
no such reduction was made here.

## Verification evidence and limits

Verified code/evidence checkpoint: `ec9a412b7bde6583130f747ea3a0e14d3b26b833`.
The later font/capture/document checkpoint needs its own exact-HEAD CI; use CURRENT
PR checks and the final handoff response, not this historical SHA, for final status.

- Targeted Web: 3 files / **14 tests PASS** (consultation, request deadlines, concierge).
- Full local Web: **56 files / 157 tests PASS**, typecheck and production build PASS.
- CF14 authoring: **37 tests PASS**, includes missing-evidence and known-defect fail-closed rules. F2 command was not run.
- Offline recovery controls: PASS after updating the Accepted governance assertion. One initial local run hit a fake-curl broken pipe; the subsequent full traced run and hosted operational CI passed.
- CI #967 / `34436954778`: **SUCCESS**, all four jobs (web, complete SQL+parallel suite, Edge lint/type/tests/auth matrix, real Supabase stack reset/integration).
- Today Navigation #30 / `34436954820`: **SUCCESS**, real Chrome mobile viewport.
- Operational Safety #62 / `34436954788`: **SUCCESS**.
- CF14 artifact `10136513346`: source HEAD above, six real Chrome scenarios including sender confirmation, `F1_AUTHORING_EVIDENCE_ONLY`, physicalDevice=false. No actual LINE/Google/OCR provider or physical-iPhone claim.
- Initial resumed CI/browser failures were investigated, not ignored: Chrome startup deadline, an API upload assembled an extra document into Requests.tsx (corrected and full file hashes subsequently checked), and the stale ADR pending-status regression. CI #966 and #967 subsequently passed. No known broken intermediate version was merged/deployed.

## CF numbering and disposition

These are scope-specific review dispositions, not a blanket re-certification of
all original integration PASS claims. Definitions checked against lane source,
commit labels and current-design registry; CF-02/03/04/05/13/16 are not interchangeable.

| CF | Scope | Astra disposition |
|---|---|---|
| CF-01 | Request canonical lifecycle | Core canonical writer retained; product closure PARTIAL because XC-03/XC-05 remain. |
| CF-02 | Today semantic truth split | Single DailyBrief path retained; scoped source/SQL/Chrome evidence green. |
| CF-03 | Today false empty / dual controller | Scoped source and loading/error/stale tests green. |
| CF-04 | Today next-action / priority | Linked first-flow hierarchy checked by existing navigation/priority evidence; physical use pending. |
| CF-05 | Today clock / daypart | Existing boundary/visibility and canonical daypart tests green; full-day F2 pending. |
| CF-06 | Concierge duplicate semantics | XC-01 corrected and SQL85 green; final whole-flow coverage still bounded. |
| CF-07 | Concierge retry/idempotency | Existing receipt/CAS semantics preserved; response-loss replay regression green. |
| CF-08 | LINE/PWA candidate semantic parity | Shared interpretation and ambiguity contracts retained; not proof of all daily LINE actions. |
| CF-09 | Explicit channel responsibility matrix | Approved matrix is present; implementation-wide compliance FAIL under XC-03. |
| CF-10 | Approved Final UX canonicalization | Registry and authority trace inspected; CF-SOL-01 corrected. |
| CF-11 | Household backup/recovery | Accepted right-sized design; actual existing workflow recovery succeeded. See unwanted automatic run incident. |
| CF-12 | Reply deadline vs work deadline | PWA/assignment semantics preserved; light-request LINE deadline presentation remains part of XC-03. |
| CF-13 | Back / return state | Existing navigation/draft evidence green; Request refresh no longer unmounts page. |
| CF-14 | Requirement evidence | F1 authoring green; overall PENDING / known implementation blockers, F2 NOT STARTED. |
| CF-15 | Release / operational enforcement | Draft recovery side-effect guard added; main merge and app production deployment remain forbidden. |
| CF-16 | PWA identity | Existing identity source retained; physical install/cache evidence remains F2. |

## Unreviewed / not closed areas

- Complete Q1–Q112 requirement→design→implementation→actual entry verification ledger.
- Whole-day/next-day interaction including all error/correction paths.
- Full Nursery image→OCR/AI→editable structured review→human confirmation through real entry. Worker retry and rich nested editing observations were not fully adjudicated.
- Actual Google provider changed/deleted/duplicate events; internal domain tests are not provider proof.
- Full regular Task editor assignment-consent paths beyond Concierge; optional-subtask-after-parent-completion edge case.
- Consultation change notification/comment delivery and structured reschedule/swap completion.
- Actual concurrent LINE/PWA commands and physical iPhone back/install/cache behavior.

## Safety incident and current boundaries

Updating ADR0014/current recovery docs triggered the existing automatic Household
recovery drill on a Draft PR. Its run #11 (`34436475187`) **completed successfully**,
including “Actual Family Ops snapshot to isolated app-save-hub namespace”. Thus a
persistent recovery-store write occurred without the requested operation approval.
The review should have inspected this path trigger before the docs push; this was
an execution mistake, not an authorized production operation.

Family Ops production source was read-only in that workflow; the write targeted
the reserved app-save-hub recovery namespace, and the restore used a disposable
Supabase stack. No Family Ops production migration, LINE/Google mutation, main
merge or application deployment was performed. Nevertheless, a broad “production
mutation/deploy: NO” would conceal the external recovery write, so this exception
must accompany the final report.

Pre-guard queued runs #12 and #13 were CANCELLED. After the Draft guard, run #14
was SKIPPED. The connected GitHub tools have no cancel-run action, so no cancellation
is claimed as an assistant action. No recovery data was deleted as compensation.

- Main merge: **NO**; PR stays Draft.
- App production mutation/deploy: **NO**.
- External recovery write: **YES, unintended automatic run #11**, as above.
- F2: **NOT STARTED**.
- Product Owner Requirement decision: **none made**; existing requirements were not reduced.
- Ready to combine with Sol's independent review: **YES, as partial findings + saved corrections**.
- Ready for F2 final acceptance: **NO**, XC-03/XC-05 remain.

## Resume without restarting

1. Fresh-read PR #79 head/checks and this record from that exact head. Preserve all pushed corrections.
2. Keep PR Draft; do not retrigger the production-reading/recovery-writing drill.
3. Prioritize XC-03 actual LINE daily entry and XC-05 structured terms effects. Reuse canonical commands; do not add a second writer or relax M01–M26.
4. Add real entry regressions for each correction; checkpoint push every completed material unit.
5. Close the remaining material requirement ledger and exact-head CI/browser gates before declaring F2-ready.

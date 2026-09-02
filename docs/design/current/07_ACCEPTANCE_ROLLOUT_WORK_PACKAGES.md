# 07. Acceptance, Rollout, and Implementation Work Packages

## 1. Purpose

本書は詳細設計を実装順序・acceptance・production gateへ落とす。

このPRは **NO IMPLEMENTATION**。独立レビューでGOになるまで実装開始しない。

CURRENT物理制約は `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`、ActorRef legacy互換は `08_ACTORREF_LEGACY_IDENTITY_COMPATIBILITY.md` を必ず併読する。

---

## 2. Detailed-design exit criteria

実装開始条件:

- BLOCKER 0
- HIGH 0
- Requirements Baseline contradiction 0
- ADR 0012/0013 normative scope明確
- CURRENT **50 tables (public 27/private 23)** disposition済み
- Request/Task/actual/assignment/shopping/Event/source Authorityのcurrent truthが一意
- task `待ち` / outcome / carryover semanticsがschema+command+DailyBriefで閉じる
- Request legacy status+timestamp CHECK互換が実行可能
- simulated actor persistenceがActorRefで一貫
- test stateがproduction read/side effectへ漏れない
- Task→Google mirror、old-target deletion queue、Family Event writerのprovider-mutation ownershipが競合しない
- orphaned provider identityがFamily Eventのwritable linkへsilent昇格しない
- aggregate read/write atomic cutover + P1後安全契約が定義済み
- Final-GO MEDIUM 3がacceptanceに入っている

MEDIUM以下をcarryする場合でも、implementerがproduct/domain truth・consent・migration meaningを発明する状態は禁止。

---

## 3. Implementation principles

- no direct main push
- no production reset/delete
- applied migration rewrite禁止
- pending/new migrationのみtimestamp順
- production catalog/schemaをmigration直前にfresh read
- one aggregateをold/new双方が独立に書くdual-write期間を作らない
- new reader + new writerはaggregate単位で同時activation
- P1後legacy current-truth read/writeへ戻さない
- test side effectはfail closed
- provider identityごとに destructive DELETEを含むmutation ownerは1つだけ
- runtimeがRequirementsを変える場合はcodeより前/同PRでrequirements review

---

## 4. Rollback classes

### R0 — pre semantic activation

Additive/evolution schema + deterministic backfill only。

- old runtime利用可能
- additive schemaは残ってよい
- no new-only production state

### R1 — canonical adapters/readers deployed inactive

- command adapter + canonical readerはdeploy済み
- aggregate gate未activation
- first new-only stateなし
- activationキャンセル可

### P1 — first new-only canonical state

Examples:

- Request checking/consulting/awaiting_confirmation
- anyone claim
- multiple performers
- waiting
- mostly_done evidence
- Family Event Authority state not representable by legacy current read

P1後:

- legacy current-truth reader rollback禁止
- legacy semantic writer rollback禁止
- incident = mutation pause + canonical/degraded read + forward-fix
- physical rollbackしない
- P1をrelease/household operation metadataへ記録

---

## 5. Work package order

### WP-DD1 — Additive/evolution domain schema foundation

Scope:

- domain ActorRef
- direct test context on canonical test-capable rows
- task assignment mode/source/claim/revision
- task waiting/outcome/policy fields
- task actual participants + compatibility-primary
- reconciliation sessions/items
- request attempts/confirmations
- Request compatibility helper prerequisites
- shopping assignment/claim/participant/revision/test fields
- Family Event/external link/candidate foundation
- children/school/source-document foundation
- DailyBrief schedule kinds + date override table
- CURRENT Google provider lifecycle guard/state needed for `family_ops_calendar_mirrors` / `family_ops_calendar_target_deletions` ownership transfer
- preservation/read treatment for `family_ops_calendar_orphaned_mirrors`
- task completion CHECK replacement
- Request CHECK catalog verification

Acceptance:

- migrations apply to CURRENT main-derived schema without destructive drop
- CURRENT task completion CHECKs are explicitly replaced before participant-first completion
- Request legacy CHECK is catalog-read and full lifecycle tuple can remain CHECK-valid
- production aggregate cannot reference simulated ActorRef
- test aggregate ActorRef/test-context equality enforced
- existing app still runs while capability gates inactive
- Task-owned mirror/deletion bridges remain valid before Family Event ownership activation
- orphan audit rows remain preserved and do not become writable links
- rollback class R0

### WP-DD2 — Deterministic backfill + compatibility/reconciliation

Scope:

- household members -> real ActorRefs
- Task assignment -> ActorRef snapshots
- legacy actual actor -> participant
- Request -> Attempt representation
- handover defaults
- task policy snapshots
- Request/Task/assignment-scope anomaly audit
- **50-table physical inventory assertion**
- CURRENT `family_ops_calendar_mirrors` provider identity/queue-state inventory
- CURRENT `family_ops_calendar_target_deletions` provider identity/delete-job/lease-state inventory
- CURRENT `family_ops_calendar_orphaned_mirrors` provider identity/reason inventory

Acceptance:

- idempotent rerun
- no guessed anyone assignment
- no guessed performer
- no guessed skipped reason
- no guessed Family Event from Task mirror or orphan record
- Request audit includes missing/invalid link, status-vs-task contradiction, timestamp contradiction, assignment scope mismatch
- every pre-cutover legacy Request tuple validates CURRENT CHECK or is explicit anomaly
- mirror inventory records projection key/kind/task/connection/provider event/etag/action/sync/lease state
- target-deletion inventory records connection/projection/provider event/sync/lease/retry/blocked state
- orphan inventory records exact provider identity/reason/observation and is treated as non-writable evidence
- unresolved anomaly blocks affected household aggregate cutover
- rollback class R0

### WP-DD3A — Test identity + side-effect sandbox foundation

Dependency: before any actual-household one-user simulation.

Scope:

- server-derived execution context
- ActorRef real/simulated/system resolution
- simulated identity across assignee/claimant/performer/recorder/request/confirmation/reconciliation/audit
- DB test-scope guards
- production-read default exclusion
- production outbox/Google/real-consent fail-closed guards
- minimal operator `🧪` synthetic delivery

Acceptance:

- no fake auth/member
- operator ID never substitutes simulated mama
- simulated mama can receive Request, confirm, be assignee/claimant/performer/recorder
- no test row in production outbox/Google write/real consent
- ordinary Today/History/Requests/shopping/handover excludes test
- Final-GO MEDIUM-3 passes at foundation level

### WP-DD3 — Canonical transaction command layer + concurrency

Scope:

- task complete/correct
- waiting set/update/resume
- assignment change
- claim/release/takeover
- group reconciliation
- Request Attempt transitions
- candidate resolution
- info ack/update
- canonical notification intent transaction hooks

Acceptance:

- operation receipt replay safe
- expected revision conflict explicit
- terminal Attempt no reopen
- no performer overwrite
- task + participant/audit/intent atomic
- skipped outcome deterministic
- LINE/PWA call same command contract
- commands executable under WP-DD3A sandbox

### WP-DD4 — Request / assignment canonical cutover

Scope:

- Request composer/read model
- `やる / 難しい / その他`
- checking/consulting/awaiting confirmation
- reply deadline
- accepted execution via linked Task
- post-accept change/cancel Attempt
- already-coordinated assignment path
- legacy Request lifecycle projection helper
- CURRENT PWA/Today/Edge/RPC/LINE direct readers/writers cutover

Acceptance scenarios:

1. pending -> accept -> one linked Task
2. checking -> deadline -> canonical expired; stale old action blocked
3. consulting one confirmation -> no formal assignment change
4. both same terms revision -> agreed change
5. terms edit invalidates old confirmations
6. accepted Request task rescheduled -> execution is Task truth
7. accepted cancel proposal does not apply until required confirmation
8. simulated recipient remains simulated ActorRef
9. **every new-runtime legacy Request tuple satisfies CURRENT status/timestamp CHECK**
10. pre-agreement checking/consulting/awaiting -> legacy pending + all terminal timestamps null
11. pre-agreement expired -> canonical expired while legacy compatibility tuple is cancelled + compatibility-only cancelled_at
12. accepted Request + pending change/cancel Attempt -> legacy tuple remains `accepted + accepted_at`; canonical reader shows negotiation
13. accepted Request + accepted/declined/expired/cancelled post-agreement Attempt never violates legacy CHECK
14. new runtime Task completion does not write Request `completed`
15. historical legacy completed rows remain preserved/backfilled without guessed execution truth

**P1 warning:** before first production new-only Attempt state, canonical reader + writer must activate together. Old UI may not interpret legacy pending after P1.

### WP-DD5 — Task actual/reconciliation + History semantics

Scope:

- multiple performers
- all_done/mostly_done/individual
- carryover result certainty
- outcome current read/history
- support analytics
- correction history

Acceptance:

- mostly_done does not change child status
- optional/余力 excluded from bulk complete
- occurrence-end unknown does not become failure metric
- until-done weak result-unknown carryover
- compact follow-up only when meaningful
- joint work counts one household completion
- `今回は不要` vs `できなかった` distinguishable without audit replay
- simulated performer/recorder excluded from production analytics
- Final-GO MEDIUM-1 PASS

### WP-DD5B — Shopping responsibility / actual / duplicate safety

Scope:

- shopping assignment mode `person|unassigned|anyone`
- ActorRef assignee compatibility
- claim/release/takeover
- shopping actual participants/recorder
- revision/concurrency
- direct test context
- duplicate-sensitive neutral completion
- undo/correction neutral notification
- shopping canonical reader/writer atomic cutover

Acceptance:

1. `牛乳を買う / 誰でもOK` -> claim -> partner sees claimed -> purchase -> neutral handled
2. claim takeover is revision safe
3. purchase clears claim and records performer atomically
4. double completion/order stale action does not create duplicate canonical actual
5. undo to actionable state emits neutral correction when partner behavior must change
6. ordinary one-person flow remains one-tap; multi-person detail is secondary
7. test shopping never appears in production shopping/DailyBrief/analytics
8. legacy `status='assigned'` does not remain a competing canonical assignment truth

### WP-DD6 — Shared DailyBrief + schedule cadence + LINE/PWA convergence

Scope:

- server DailyBrief
- PWA Today
- LINE `今日`
- weekday morning 06:30
- weekend/holiday morning 09:00
- evening 20:30
- date-specific schedule override
- partner summary
- waiting checks
- all-day schedule display
- deep links
- legacy nine-kind push suppression

Acceptance:

- same Task/Request state in LINE/PWA
- waiting future-check excluded from normal nag
- next check resurfaces without auto resume
- hard deadline risk visible while waiting
- own daily Task titles visible in LINE
- completed morning normal details collapse in evening
- PWA mutation does not full reload/scroll top
- stale deep link resolves latest state
- base 06:30/09:00/20:30 persists
- one-day override time works without changing base schedule
- one-day skip/disable works
- old routine schedule rows do not keep producing normal-day extra pushes after cutover
- scheduled dispatch receipts dedupe new brief kinds
- **all-day Family Event appears without fake 00:00**
- **Google all-day occurrence appears in DailyBrief**
- **same all-day event does not create timed assignment conflict**

### WP-DD7 — Notification policy + duplicate-sensitive safety

Scope:

- immediate vs digest policy
- neutral handled state
- waiting check/deadline policy
- stale intent suppression
- bundling
- quota preservation

Acceptance:

- normal partner task completion does not praise-push
- medication/transport/purchase/submission duplicate-sensitive event can change partner behavior neutrally
- undo/correction can reverse stale handled belief neutrally
- waiting does not routine-nag before next check absent hard risk
- stale reminder suppressed after resolution
- LINE quota protections unchanged
- Final-GO MEDIUM-2 PASS

### WP-DD8 — Family Event + Google Authority + CURRENT provider lifecycle bridges

Scope:

- Family Event aggregate
- field Authority
- external links
- change candidates
- Google inbound reconciliation
- owned/external-follow behavior
- existing Task→Google mirror bridge boundary
- old-target deletion bridge boundary
- permission-loss/orphan observation boundary
- ownership-transfer/adoption protocol
- mirror trigger/worker guard
- target-deletion claim/worker destructive-write guard
- prep reschedule candidates

Acceptance:

1. protected Family Ops event changed in Google -> candidate, no silent overwrite
2. external-follow field updates safely
3. local+external concurrent change -> conflict diff
4. Google delete does not erase completed prep/history
5. duplicate candidate links existing Google event without duplicate create
6. existing OAuth/watch/sync/cache/write idempotency retained
7. transport `family_ops_calendar_mirrors` continues as Task-owned bridge
8. existing special Task mirror is **not** auto-converted to Family Event
9. explicit special-Task provider event adoption preserves exact provider_event_id/ETag; no title/date lookup
10. processing Task-mirror lease cannot be raced during transfer
11. pending/failed/blocked Task mirror reconciles or blocks transfer; no silent discard
12. Task mirror is marked/guarded as superseded before Family Event writer takes ownership
13. transferred projection cannot be re-enqueued by Task trigger
14. matching `family_ops_calendar_target_deletions` pending/failed/blocked job is reconciled and made terminal non-mutating before Family Event ownership; processing live lease blocks transfer
15. deletion job already completed means the deleted provider identity is not adopted as a live external link
16. target-deletion worker revalidates provider ownership before DELETE; superseded ownership produces no provider mutation
17. matching `family_ops_calendar_orphaned_mirrors` row blocks adoption until provider access + exact event identity/ETag are freshly revalidated, or a different eligible event is intentionally linked
18. orphan audit row alone never becomes a writable Family Event external link
19. **provider-mutation overlap audit across Task mirror + target-deletion queue + Family Event writer = zero before Family Event P1**
20. unresolved mirror/deletion/orphan lifecycle anomaly blocks affected cutover
21. prep waiting uses Task attention state

### WP-DD9 — Nursery/Codmon image intake

Scope:

- private source storage
- extraction processing
- child/school recognition
- source fact vs AI inference
- review UI
- monthly/recurrence/update/URL handling
- raw deletion

Acceptance:

- マサキ/すだち and ウタノ/ゆき never cross-school merge
- unrelated other-child information not durable structured business data
- source fact visually distinct from AI suggestion
- school preparation rule only after user confirmation
- raw image can be removed while confirmed household data/history remains
- update notice creates candidate/history, not silent overwrite
- all-day school event flows into WP-DD6 display acceptance

### WP-DD10 — One-user test UX completion / real-spouse transition

WP-DD3A is the safety foundation. This package is UX/polish/transition only.

Scope:

- richer synthetic operator delivery
- simulation management/history
- real spouse transition
- archive test context

Acceptance:

- synthetic LINE shows `🧪`
- no production outbox/Google/real consent
- production analytics excludes test
- real spouse does not inherit simulated agreements
- useful unresolved simulated item may only become a new reviewed production proposal
- Final-GO MEDIUM-3 remains PASS

### WP-DD11 — Production migration/cutover audit

Scope:

- capability gates
- compatibility/degraded readers
- P1 checkpoints
- production reconciliation
- monitoring/runbook
- test leakage audit
- Google provider mutation ownership audit

Acceptance:

- no divergent old/new writer
- current rows reconcile to canonical reads
- no orphan accepted Request
- no participant loss
- Request legacy CHECK audit clean
- notification duplicate audit clean
- Today/dispatch/History/Requests/shopping/handover test leakage = zero
- production outbox/Google test leakage = zero
- Task mirror vs target-deletion queue vs Family Event provider mutation overlap = zero
- unresolved Google orphan/provider lifecycle anomaly count = zero for households/events crossing Family Event P1
- each capability declares R0/R1/P1
- P1 feature-off never restores legacy current truth
- forward-fix/mutation-pause runbook exists

---

## 6. Capability gate strategy

Prefer aggregate capabilities, not one giant `vNext` flag.

Examples:

- `test_actor_foundation_v1`
- `request_negotiation_v2`
- `actual_reconciliation_v2`
- `shopping_responsibility_v2`
- `daily_brief_v2`
- `family_event_authority_v1`
- `nursery_intake_v1`
- `one_user_simulation_v1`

Rules:

- server-side household capability
- frontend reads capability, not environment guess
- reader/writer pair activates together
- new-only write not enabled while incompatible old reader active
- gate metadata records P1
- P1-crossed capability cannot route to legacy current truth

---

## 7. Recommended rollout order

1. WP-DD1 schema/constraint readiness, feature off (R0)
2. WP-DD2 backfill/reconciliation, including all 50 CURRENT tables and Google provider-lifecycle inventory
3. WP-DD3A test safety foundation
4. WP-DD3 canonical commands under sandbox
5. one-user internal simulation with external side effects blocked
6. WP-DD4 Request atomic cutover
7. WP-DD5 actual/reconciliation atomic cutover
8. WP-DD5B shopping atomic cutover
9. WP-DD6 DailyBrief + schedule consolidation
10. WP-DD7 notification safety
11. WP-DD8 Family Event/Google Authority + provider-lifecycle ownership cutover
12. WP-DD9 nursery intake
13. WP-DD10 one-user UX/real-spouse transition
14. WP-DD11 production audit/operational hardening continuously across releases

Family Event implementation may be developed earlier, but provider ownership must not cut over until mirror/deletion/orphan reconciliation and destructive-write guards are ready.

---

## 8. Production safety gate before every migration/deploy

- fresh main SHA
- production migration history
- actual schema/constraint catalog precondition
- only pending migration timestamp order
- no db reset
- no applied migration replay
- no production data delete
- backup/recovery readiness for schema-affecting work
- Edge Function auth matrix before deploy
- queue/outbox lease state understood before queue ownership migration
- provider deletion/orphan state understood before Family Event ownership transfer
- deployment/cutover operation recorded

---

## 9. Required release evidence

For each capability release retain:

- code SHA
- migration IDs applied
- pre/post schema reconciliation result
- aggregate gate state
- P1 crossed yes/no + timestamp
- anomaly counts
- test leakage counts
- notification/Google side-effect audit
- rollback class/runbook

For Family Event Google ownership also retain:

- Task mirror row counts by sync_state
- target-deletion row counts by sync_state including blocked
- orphaned mirror count + disposition/revalidation result
- transferred provider identities
- unresolved provider lifecycle anomalies
- exactly-one-provider-mutation-owner audit result

---

## 10. Final implementation gate

Do not begin implementation until independent design review returns GO.

After implementation starts, do not advance a work package to production unless its acceptance and production-safety checks are satisfied.

Any detected product-truth ambiguity, test identity leakage, Request CHECK incompatibility, unaccounted CURRENT table, or Google provider-mutation ownership ambiguity returns the affected aggregate to design/migration review rather than being decided ad hoc in code.

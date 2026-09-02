# 05. Google / Image / AI Authority, Conflict, and Privacy Design

## 1. Goal

外部情報を便利に取り込む一方、`newest wins`やAI自動確定で家庭の合意・予約済み内容を壊さない。

対象:

- Google Calendar
- nursery notice / Codmon screenshot
- user-entered/manual values
- AI inference

共通のAuthority/candidate modelを使う。

## 2. Authority levels

### A. Human protected current value

Examples:

- user manually created/edited event
- conflict diffをuserが明示解決
-夫婦が合意したassignment/time
- nursery extractionをuserがconfirmした家庭情報

External source/AI cannot silently overwrite.

### B. External-follow current value

Linked sourceをfollowすることが明確なfield。

Example:

- Google-origin eventを「Googleをfollowする予定」としてlinked

External update can auto-apply only if:

- field authority is external-follow
- local protected edit has not occurred
- update passes validation

### C. Source observation/fact

External data as observed:

- Google event cache
- nursery document explicit text/date

Observation is not automatically Family Ops current truth.

### D. AI inference

Always proposal/candidate.

Never directly changes:

- assignee
- event date
- cancellation
- request acceptance
- Google write
- recurrence rule

without human-confirmed command.

## 3. Unified candidate lifecycle

Candidate states:

- pending
- accepted
- rejected
- stale
- superseded

Every candidate includes:

- source type/ref
- proposed patch
- target ID or create intent
- target revision/hash at candidate creation
- explanation/fact-vs-inference label

Accept checks latest target revision.

If current target changed:

- candidate -> stale
- recompute diff
- user sees latest current + proposed

No blind patch over newer state.

## 4. Google architecture inheritance

Retain v6 transport/security rules unless explicitly changed:

- separate OAuth/auth binding
- encrypted refresh token
- household composite binding
- provider webhook verification
- durable/coalesced sync jobs
- canonical `calendar_events_cache`
- Google-expanded occurrence projection
- no local RRULE parser
- deterministic write idempotency
- PATCH/If-Match, no blind update
- creator != busy member
- all-day/transparent conflict behavior per current accepted design unless later requirement changes

The major change is **Family Ops event truth**.

v6 statement that shared Google calendar is the family schedule source of truth is superseded for product behavior by Requirements Baseline/ADR 0012 where necessary: Family Ops must protect human-confirmed values and cannot interpret Google deletion/change as unconditional canonical mutation.

ADR 0013 explicitly records this architecture evolution.

## 5. Family Event ↔ Google link modes

### 5.1 `family_ops_owned`

Event originated/was explicitly protected in Family Ops and is mirrored to Google.

- Family Ops current field = canonical
- Family Ops -> Google write allowed for owned fields
- Google-side edit to protected field -> candidate conflict
- no automatic local overwrite

### 5.2 `external_follow`

Event originated in Google and user chose link/follow semantics.

- designated fields can track Google
- Google update auto-applies if no local protected edit
- once user explicitly edits/resolves a field in Family Ops, that field becomes human-protected until user changes policy via explicit action

Link mode can be event-level; field_authority refines individual fields.

## 6. Google inbound update algorithm

For each linked event:

1. sync provider event into existing canonical Google cache
2. identify external link
3. compare owned fields against `last_external_snapshot`
4. for each changed field:
   - if field authority=`external_follow` and local current still matches prior external baseline -> auto-apply
   - else -> create change candidate
5. update external snapshot/etag observation metadata
6. do not mark candidate accepted merely because sync succeeded

A provider sync transaction and a Family Ops candidate acceptance are separate responsibilities.

## 7. Three-way comparison

Use:

- previous external snapshot
- current Family Ops value
- new external snapshot

Cases:

1. local==previous external, external changed, authority follow -> safe auto-update
2. local!=previous external, external changed -> candidate conflict
3. external unchanged, local changed -> retain local; outbound write policy may update Google if Family Ops owned
4. both changed to same value -> reconcile as no conflict

This avoids simple timestamp newest-wins.

## 8. Google date/time change and prep tasks

When Family Event effective time changes:

- event itself follows authority result
- incomplete prep tasks linked relative to event may receive reschedule candidates
- completed prep actuals are never rewritten
- protected/manual/reservation tasks are not auto-shifted
- warnings are generated for incompatibility (e.g. lunch reservation now too close)

Relative prep can store relation metadata:

- offset from event start/date
- preferred daypart
- hard/soft relation

But dependency DAG is not required.

## 9. Google deletion

Provider deletion does not directly delete Family Event.

For linked event:

- record external tombstone in cache
- create candidate offering:
  - cancel Family Event
  - mark waiting_reschedule
  - keep Family Event / unlink or stop Google visibility

If Family Event was purely external-follow and has no protected Family Ops semantics, UI may strongly recommend cancel but still preserves review flow where linked prep/history exists.

Completed task actuals remain.

## 10. Google duplicate/link detection

When publishing/linking a Family Event:

candidate matches use:

- same/similar title
- overlapping start/end
- same day
- existing external operation marker/link

Never auto-merge based on title alone.

User choices:

- link existing Google event
- create separate Google event
- cancel publish

Once linked, unique constraint prevents two Family Events silently owning same Google occurrence/resource unless explicit future design supports it.

## 11. Concurrent Google + nursery candidates

If same event receives:

- Google time candidate
- nursery correction image candidate

before human resolution, UI builds one conflict workspace:

- current Family Ops value
- Google proposed value
- nursery explicit fact
- AI prep implications

Each source remains separately traceable. UI may recommend the stronger/more relevant source but does not collapse evidence into one opaque AI choice.

## 12. Nursery/Codmon intake pipeline

### 12.1 Intake initiation

Sources:

- LINE image
- PWA upload
- future share extension

The raw file is stored privately before asynchronous processing if user selected/intended notice analysis.

Normal family photo should not become a long-lived OCR job unless user explicitly asks.

### 12.2 Processing stages

1. classify document type
2. detect likely child/school/class context
3. extract explicit facts only into structured candidates
4. derive AI preparation suggestions separately
5. duplicate/update/conflict matching
6. present review
7. human confirms selected items
8. standard commands create/update Event/Task/Info/Recurrence

## 13. Child/school context matching

Known household context:

- マサキ / すだちぐみ / school-context A
- ウタノ / ゆきぐみ / school-context B

They are different schools.

Matching features:

- school name/logo
- class text
- known UI pattern
- notice account context if available
- document history aliases

Rules:

- class label alone cannot bridge different school contexts
- ambiguous match remains candidate
- user confirms only affected extraction
- confirmed aliases can be learned

## 14. Third-party information minimization

Raw image may include other children/class names.

Durable structured persistence must keep only information relevant to household child/context and necessary source evidence.

Do not persist:

- full class roster OCR text
- unrelated child names as entities
- unrelated contact details
- model-extracted third-party profiles

If raw source is retained, access remains household-private and retention-controlled.

## 15. Explicit fact vs AI inference

Extraction output must carry origin.

Example:

`source_explicit`
- `9/20 食育`
- `持ち物: エプロン`

`ai_inference`
- `三角巾も必要かもしれません`
- `前夜に準備するとよさそう`

UI and API must not present AI inference as `お知らせに記載`.

AI suggestions can reference confirmed school preparation rules distinctly:

`家庭で確認済みルールから提案`

This is stronger than free inference but still a Family Ops suggestion, not school statement.

## 16. School preparation rule learning

A mapping becomes confirmed rule only after explicit user confirmation.

Example:

- trigger: event type `食育`
- prep: `エプロン`
- child_school_context_id A
- effective dates

Do not promote from repeated model inference automatically.

When school/class changes, old rule remains history and does not silently apply to new school context.

## 17. Monthly schedule extraction

For a dense monthly schedule:

- parse all relevant household-child entries feasible
- prioritize registration recommendations:
  - required items
  - clothing instruction
  - parent attendance/action
  - time change
  - submission deadline
- remaining entries stay inspectable under `その他`

AI ranking does not delete lower-priority source facts.

## 18. Recurring rule extraction

Source text such as:

`7〜8月 毎週火・木 プール`

becomes a recurrence candidate with:

- effective_from/effective_to
- weekday set
- event/task kind
- linked preparation suggestion

User sees generated dates/range before confirm.

Never create permanent recurrence by omitting end date when source clearly indicates a period.

## 19. One-off exception extraction

`今週木曜のプールは金曜へ変更`

should not edit recurrence definition.

Candidate bundle:

- cancel/override Thursday occurrence
- create/move Friday occurrence
- shift only linked preparation for that occurrence if appropriate

Link source image to the exception history.

## 20. Submission and action destination

For forms/QR/URL:

candidate can produce task fields:

- action method (`codmon`,`web`,`paper`,`bring`)
- destination URL if confidently extracted
- source document link

URL security:

- parse/normalize URL
- allowed schemes http/https only
- display hostname before open
- no auto-submit
- QR decode confidence/format checked
- suspicious/malformed URL requires explicit confirmation or is not promoted

Do not invent missing URL from text/domain guess.

## 21. Raw image privacy invariant

### 21.1 Storage

- private bucket only
- object key non-guessable
- no public URL
- signed access only after membership auth
- object metadata binds household/source document

### 21.2 Access

Both household adults may view source if record visibility is household and test context permits.

No external share by default.

### 21.3 Retention

Initial retention value is detailed implementation config, not requirement. Design must support:

- user delete anytime
- scheduled cleanup after policy date
- important source keep override if product chooses later

### 21.4 Delete semantics

Raw delete:

- delete object
- mark source document `raw_deleted_at`
- keep confirmed Family Ops events/tasks/info/history
- keep minimal source provenance (document ID/type/date) as allowed
- no resurrection from cache/backups through normal product path

Backup retention handling must be documented operationally; logical deletion does not promise instant physical erasure from immutable backups beyond backup policy.

## 22. AI model/privacy boundary

AI/vision call receives only minimum required document/context.

Do not send unrelated household history by default.

Prompt context can include:

- candidate child/school aliases
- confirmed school prep rules
- current candidate event dates for duplicate matching when needed

Never include:

- Google refresh token
- LINE secrets
- auth token
- unrelated raw private request text

Persist model metadata/version/confidence, not hidden chain-of-thought.

## 23. AI failure handling

- model timeout -> intake remains retryable
- partial extraction -> show partial with warning only if valid
- invalid structured schema -> reject output, no business mutation
- low-confidence child/date -> ask targeted confirmation
- conflicting pages -> show conflict, do not choose silently

## 24. Source revision/update matching

New photo may be:

- same notice additional page
- same notice rephoto
- revised notice
- unrelated notice

Matching signals:

- school/class
- dates/title
- source layout/document identifiers if present
- temporal proximity

System proposes relation; user can separate.

Revised notice creates new source observation and change candidate, preserving old source/history.

## 25. Acceptance scenarios

Mandatory review/test scenarios:

1. Family Ops-created protected event changed accidentally in Google
2. Google-origin external-follow event changed normally in Google
3. Google delete with prep tasks and completed prep actual
4. duplicate Google event linking
5. Google and nursery image propose different dates concurrently
6. マサキ notice includes another class — only すだち relevant facts retained
7. ウタノ Codmon screenshot correctly isolated from マサキ school rules
8. source says 食育 but no 三角巾; AI suggestion visibly separate
9. user confirms new prep rule, future notice uses it as household rule suggestion
10. monthly schedule with 30+ entries prioritizes only household-impacting items without losing reviewability
11. recurring summer pool + one moved occurrence
12. QR malformed/low-confidence
13. raw image deleted after confirmation; event/task remain and later correction works with `元画像なし` indicator
14. updated notice conflicts with human-confirmed date

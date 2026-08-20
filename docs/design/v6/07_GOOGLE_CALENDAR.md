# 07. Google Calendar — v6 normative

## 1. Source of truth

Family schedule source of truth is one shared Google secondary calendar.
Family Ops DB stores canonical cache + rolling occurrence projection.

## 2. Authentication separation

App login and Calendar OAuth are separate.

Calendar OAuth:
- offline access
- exact scopes: `https://www.googleapis.com/auth/calendar.events` and `https://www.googleapis.com/auth/calendar.calendarlist.readonly` only
- refresh token encrypted server-side
- connection owner linked to same household by composite FK

### Publishing status gate
Before real family use, OAuth consent project must be **In production**.
When kept in Testing, Calendar-scope refresh tokens can expire after 7 days; runbook must treat repeated `invalid_grant` as expected testing behavior and require reauth.

## 2A. OAuth state/replay

MVP flowは **confidential web-server client + state、PKCEなし** に固定。

Start:
1. JWT user + household membership verify
2. random 256-bit state
3. DBにはSHA-256 `state_hash`のみ保存
4. `private.google_oauth_states`へ user/household/return_to/10m TTL binding
5. raw stateをauthorization URLへ

Callback:
1. raw state hash
2. row `FOR UPDATE`
3. unused/unexpired確認
4. stored user/household bindingを正本にする
5. code exchange
6. durable refresh token encrypt/store
7. state.used_at set same transaction boundary
8. reuse/expired state reject

`return_to`はallowlisted app-relative pathだけ。

## 3. Credential binding

`private.google_connections` includes household_id.
`calendar_connections` can only reference a Google credential with same household_id.
Cross-household binding must fail at FK level.

## 4. Watch channel

Store multiple overlapping channels.

Webhook verify:
- Channel-ID
- Resource-ID
- Channel-Token

Unknown/stopped/expired/mismatched valid HTTP request:
- **return 2xx and ignore**
- emit structured warning counter/log
- do not enqueue sync

No 4xx retry storm for stale valid-provider channel notifications.

## 5. Renewal

1. create new watch
2. persist new active row
3. accept old+new overlap
4. both coalesce to same sync job
5. stop old
6. mark stopped

## 6. Canonical incremental sync — exact query contract

Canonical streamはrecurring master/tombstoneを保持する。local RFC5545 expansionは禁止。

### Initial full sync
Google `events.list` parameters exactly:
- `calendarId=<selected calendar>`
- `singleEvents=false`
- `showDeleted=true`
- `maxResults=2500`
- `pageToken` only when paginating
- **no** `timeMin`, `timeMax`, `orderBy`, `q`, `updatedMin`, `privateExtendedProperty`, `sharedExtendedProperty`, `syncToken`

Process all pages. `nextSyncToken` appears on final page; only final successful reconcile後にstore。

### Incremental sync
Same fixed parameters as initial plus:
- `syncToken=<stored token>`
- `pageToken` while paginating

Do not add filters that change the collection.
All pages processed before token advance.

### 410 Gone
1. create `sync_run_id`
2. rerun Initial full sync into `private.google_event_staging`
3. each staged row PK=`(sync_run_id,google_event_id)`; duplicate same id is deterministic upsert
4. page2+ failure => live cache/token untouched
5. final page + nextSyncToken obtained => one DB transaction:
   - reconcile live canonical cache against staged set
   - create/update tombstones as required
   - store new nextSyncToken
   - mark sync success
6. after commit cleanup staging
7. abandoned staging TTL=24h

## 7. Deleted/cancelled/untitled resources

Schema must match provider guarantees.

### untitled normal event
`title=null` allowed; UI displays `（無題）` fallback.

### ordinary deleted event
Provider may return only ID/status metadata.
- never require title/start/end
- remove/terminalize active local projection
- minimal ordinary deleted tombstoneを30日保持してからcleanup

### cancelled recurring exception
May contain only:
- id
- recurringEventId
- originalStartTime

Keep minimal canonical tombstone while parent recurring event is canonical-active, or until the projection horizon has passed the exception date, whichever is later.
Do not create active occurrence.

## 7A. Recurring occurrence identity

```text
originalStartTimeKey(event):
  if originalStartTime.date:
    "date:" + YYYY-MM-DD
  else:
    normalize originalStartTime.dateTime instant to UTC second precision
    "datetime:" + RFC3339_Z

occurrenceKey(event):
  recurring -> "rec:" + recurringEventId + ":" + originalStartTimeKey
  one-off -> "event:" + event.id

classificationSubjectId(event):
  recurringEventId ?? event.id
```

Moved instance actual start is not identity.

## 8. Rolling occurrence projection — Google-expanded instances

Canonical syncToken streamとは別query。Googleにrecurrence expansionを任せる。

Window default: past 7d / future 60d, Asia/Tokyo boundaries converted to RFC3339 UTC.

Google `events.list` parameters exactly:
- `calendarId=<selected calendar>`
- `singleEvents=true`
- `showDeleted=false`
- `timeMin=<windowStart RFC3339>`
- `timeMax=<windowEnd RFC3339>`
- `orderBy=startTime`
- `maxResults=2500`
- `pageToken` while paginating
- **no syncToken**

Projection handles provider-returned:
- expanded recurring instances
- moved exceptions
- all-day exclusive end
- title nullable
- transparency

Cancelled/deleted instanceはactive projectionへ入れない。
Canonical tombstone/exception cacheが削除意味論を保持する。

Local RRULE/RDATE/EXDATE parserをMVPで実装しない。

### Manual busy classification persistence
Projection row自体をmanual source of truthにしない。
`public.calendar_busy_classifications`を毎projection rebuild後に再適用。

Precedence:
1. exact occurrence override `(google_event_id,original_start_time_key)`
2. event/series default `(google_event_id,null)`
3. Family Ops extended metadata
4. unknown

## 9. Busy attribution

**Creator != busy person.**

### Family Ops-created event
Before create user chooses:
- 自分の予定
- 相手の予定
- 家族の予定
- 未指定

Server writes private extended properties:
- `familyOpsOperationId`
- `familyOpsBusyMemberIds` where known

Sync rebuilds `calendar_occurrence_busy_members` from metadata.

### Direct Google-created event
If metadata missing:
- busy owner=unknown
- creator is not automatically busy owner
- no user-specific conflict warning
- PWA may later allow manual classification

### transparency
`transparent` => conflict ignored.

### all-day
MVP fixed rule: all-day event is **always excluded from assignment conflict detection**.
No unimplemented toggle.

## 10. Conflict detection

Task side:
- planned assignee
- due_at produced from recurrence scheduled local time
- conflict window default 60m per rule

Calendar side:
- occurrence busy member contains same user
- non-transparent
- timed event only

Overlap => warning only.
Never auto-reassign.

Unknown busy owner => no false-positive person warning.

## 11. Create idempotency

One fixed method.

For Family Ops operation UUID `xxxxxxxx-xxxx-...`:
- Google event ID = `fo` + UUID lowercase hex without hyphens
- UUID hex uses only allowed base32hex subset and length is valid
- store same operation UUID in extended private property
- provider insert uses `sendUpdates='none'`

`private.google_write_operations` claimed before provider call.

### response lost
Retry uses same remote event ID.

### 409 duplicate
GET same event ID.
Verify operation marker/request semantic hash.
- match => success/reconcile
- mismatch => conflict; do not overwrite

Same operation ID + different local payload is blocked earlier by mutation receipt.

## 12. Update idempotency/concurrency — PATCH only

1. GET current remote event
2. verify target/etag
3. build PATCH only for Family Ops-owned/explicitly edited fields
4. merge existing `extendedProperties.private`, preserving unrelated keys
5. `events.patch` with `If-Match`
6. `sendUpdates='none'`

Do not include attendees/reminders/attachments/conferenceData unless a future feature explicitly owns them.
Do not use `events.update` in MVP.

Timeout:
- GET remote and reconcile before retry

412:
- GET latest
- already desired owned fields => success
- otherwise `CALENDAR_ETAG_CONFLICT`

No blind overwrite.
## 13. Cache notification attribution

Creator mapping is for display only:
- if creator_external_id confidently maps to household member, UI may show `パパが追加`
- direct edit actor cannot always be known; do not claim editor identity

Busy member is separate table and never derived from creator automatically.

## 14. Weekly digest integration

Sunday weekly digest uses occurrence projection for next Monday-Sunday.
A preflight sync enqueue occurs ~10m before digest.
If cache remains >60m stale or reauth required, digest still sends household assignments and clearly marks Calendar section stale.

## 15. Tests

Mandatory fixtures include:
- untitled event
- id-only deleted event
- minimal cancelled recurring exception
- sync token advances despite nullable fields
- backend create success + response loss
- same operation retry => one event
- 409 duplicate recovery
- operation payload mismatch deny
- update timeout recovery
- 412 conflict
- papa creates mama event => mama busy only
- family event => both busy
- unknown direct event => no person conflict
- transparent event => ignored
- all-day => ignored


## 5A. Selected calendar eligibility

On target selection, connection refresh, target switch, and 403:
Allowed accessRole:
- writerWithoutPrivateAccess
- writer
- owner

Reject:
- reader
- freeBusyReader

MVP target `timeZone` must be `Asia/Tokyo`; otherwise `CALENDAR_TIMEZONE_UNSUPPORTED`.

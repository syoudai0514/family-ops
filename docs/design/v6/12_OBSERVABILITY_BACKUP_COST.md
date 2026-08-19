# 12. Observability / Backup / Cost

## 1. Structured logs

Allowed:
- request id
- function
- internal resource UUID
- status
- latency
- retry count
- lease owner
- queue row id
- Google connection id

Forbidden:
- raw partner text
- OAuth plaintext token
- token encryption key
- LINE secret/token
- Gemini key
- full sensitive webhook payload

## 2. Operational health

Track:
- webhook_inbox queued/processing/dead age
- notification_outbox queued/sending/dead age
- pending_actions stuck/expired/dead
- google_sync_jobs age/dead
- google_sync_state last success
- google watch expiry/retiring age
- calendar projection freshness
- cleanup last success
- LINE provider monthly usage / limit / soft budget / reserve
- LINE quota fallback count by priority

## 3. Alert thresholds (MVP admin screen/log)

- LINE inbox oldest pending >5min -> warning
- notification pending >10min -> warning
- Google last sync >60min -> warning
- watch expires <12h with no replacement -> critical
- dead queue count >0 -> admin warning
- cleanup age >48h -> warning

## 4. Supabase Free pause recovery

Runbook:
1. resume project
2. DB health
3. secrets/functions
4. Google token decrypt/refresh
5. mark expired watch
6. establish new watch
7. enqueue full/incremental sync
8. LINE health
9. queue reclaim
10. backup health

## 5. Backup

MVPはSupabase Cron側に`backup-health-check`を置かない。
Backup jobのsource of truthはGitHub Actions。

Daily workflow:
1. Supabase CLI logical dump
2. age encrypt in runner
3. R2 private bucket upload
4. same workflowでR2 HEAD
5. uploaded object size verify
6. encrypted file SHA-256 metadata/sidecar verify
7. any mismatch => workflow fail
8. success時のみjob success

GitHub Actions failure notificationを運用アラートにする。
In-app backup health表示はMVP外。

### key separation

CI stores:
- `BACKUP_AGE_PUBLIC_KEY`
- R2 credentials
- DB credential

CI **does not store age private key**.

private key:
- owner password manager and/or offline encrypted copy
- only manual restore environment

Restore drill:
- monthly or before release
- blank test target
- decrypt locally/manual
- restore
- row counts
- RLS smoke
- app read smoke

## 6. Retention

Database operational retention:
- google_sync_jobs done 14d / dead 90d
- google_write_operations succeeded/conflict 90d / dead 180d
- line_quota_state 3 months
- ordinary Google deleted tombstones 30d
- cancelled recurring exceptions: parent/horizon rule in 07
- worker_run_receipts 90d

Backup retention:
- daily backups: 30
- monthly backups: 12 if capacity allows
- adjust only after measured size/cost

## 7. Cost target

Target:
- Supabase Free
- Gemini free quota
- LINE Communication Plan monthly provider limit with soft budget=180/reserve=20
- Google Calendar API normal quota
- GitHub Actions included allowance
- R2 free/low-cost range

Graceful degradation:
- AI quota -> manual forms
- LINE quota -> in-app
- Google error -> cached events + warning + retry
- R2 failure -> local job fail + alert; never silently mark backup success


## v6 free-operation telemetry

LINE:
- provider limit/consumed
- app cap 200
- active reservations
- fallback/delivery_unknown
- 180 reminder fallback
- 190 reserve-low warning
- 200 no counted Family Ops push

Supabase Edge:
- warn 350k/month
- investigate 400k
- target below Free 500k

R2:
- Standard only
- usage alerts for storage/operations

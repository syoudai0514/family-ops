# Production connection status

Lane C operational-safety audit: 2026-09-09 (Asia/Tokyo).
Provider rows outside CF-11 / CF-15 retain their previous 2026-08-21 audit unless a
newer result is stated below. “Live test済” means a real provider response was
observed; a successful deployment, source test, or queue insert alone is not
treated as provider delivery.

For mutable GitHub state (PR HEAD, CI, rulesets, branch protection), **live
GitHub is the authority**. This status file intentionally does not claim its own
commit SHA as the current PR HEAD because updating this file changes that SHA.
Always fresh-read PR #68 and `main` immediately before a release decision.

| サービス | 接続元 | 接続先 | 必要secret / control | production設定済 | live test済 | 状態 | 残作業 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Vercel PWA | iPhone Safari | `family-ops-web.vercel.app` | `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` | 設定済（既存デプロイ） | 2026-09-09公開入口HTTP 200 / PWA shell確認 | 稼働中 | `main` が Production Git branch の方針を維持。Lane C PR #68ではPreview deploymentを再有効化しない |
| Supabase Auth: Google Sign-In | PWA | Supabase Auth / Google | Supabase AuthのGoogle client ID/secret（VITEへは不要） | 未確認・有効化されていない実測あり | 失敗 | ブロック | Supabase DashboardでGoogle providerを有効化し、redirect URLを登録 |
| LINE webhook | LINE Developers | `line-webhook-receiver` | `LINE_CHANNEL_SECRET` | 設定済との既存確認 | Webhook verify成功（既存手動確認） | 受信側確認済 | Webhook URL / Use webhook ONを監査ワークフロー実行時に再確認 |
| LINE Messaging push | `send-notifications` | LINE Messaging API | `LINE_CHANNEL_ACCESS_TOKEN` | 設定済・新tokenへ更新済 | 済（実端末受信、outbox成功1件） | 稼働中 | tokenをログへ出さない運用を継続 |
| LINE account link | PWA / inbox worker | `private.line_user_links` | `LINE_OA_BASIC_ID`（任意）, `CRON_WORKER_TOKEN` | active link 1件・世帯/設定整合1件 | 済 | 稼働中 | `LINE_OA_BASIC_ID` を設定すればワンタップ連携（Issue #5） |
| Supabase pg_cron / pg_net | pg_cron | LINE worker Edge Functions | `CRON_WORKER_TOKEN`（Vault） | 3 jobとも有効・毎分 | 済（直近run成功） | 稼働中 | 定期監視を将来追加 |
| GitHub Actions | manual dispatch | Supabase Management API | `SUPABASE_ACCESS_TOKEN` | 設定済（実行成功） | 済 | 稼働中 | E2E workflowが`outbox.status=sent`のみ成功にする |
| Google Calendar OAuth/API/watch | Calendar Edge Functions | Google Calendar API | `GOOGLE_CALENDAR_CLIENT_ID`, `GOOGLE_CALENDAR_CLIENT_SECRET`, `GOOGLE_CALENDAR_REDIRECT_URI`, `GOOGLE_TOKEN_ENCRYPTION_KEY`, `GOOGLE_CALENDAR_WEBHOOK_URL`, `APP_BASE_URL`, `CRON_WORKER_TOKEN` | 未設定として扱う | 未実施 | 後回し | Google Cloud OAuth client/API/consent screenと監視cronを設定後にE2E |
| Gemini | `propose-ai-draft` Edge Function | Gemini API | `GEMINI_API_KEY`, `GEMINI_MODEL_REWRITE` | 設定済との既存確認 | 未実施 | 要監査 | PWAのAI言い換えでprovider応答を確認 |
| Encrypted DB backup | GitHub Actions `backup.yml` | production Supabase → private Cloudflare R2 | `SUPABASE_DB_URL`, `BACKUP_AGE_PUBLIC_KEY`, `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET_NAME` | **未完了**。main上の2026-09-09再実行では`SUPABASE_DB_URL`空。PR #68ではSupabase互換logical bundle方式へ修正済みだが未merge | 失敗 | **RED** | Secrets/R2を設定し、CURRENT mainのactual backup SUCCESS・non-empty encrypted bundle・marker更新を実証 |
| Backup freshness | GitHub Actions `backup_freshness_alert.yml` | R2 `latest-backup.txt` + referenced encrypted object | `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET_NAME` | **未完了**。2026-09-09再実行でも4項目が空 | 失敗 | **RED** | actual freshness SUCCESS、exact 26h policy内、marker参照object存在/非0byteを実証 |
| Restore readiness | owner local/manual | R2 encrypted backup → fresh disposable Supabase environment | owner-held age private key + R2 read credentials | private keyは意図的にGitHub/CI外 | 未実施 | **RED / NOT EVIDENCED** | 実際のFamily Ops復旧条件として、`scripts/restore_drill.sh`を新規disposable Supabase環境に実行し、migration/core data sanityまで`RESULT: PASS`を取得 |
| Repository enforcement | GitHub repository | `main` | active ruleset / branch protection | **未設定**。2026-09-09 fresh-readで`protected=false`, required checks enforcement off, rulesets `[]` | 実効保護なし | **RED** | PR必須、5 checks必須、force-push/delete禁止、bypass actorなしのactive main rulesetを管理者が適用し、privileged verifierで確認 |

## Lane C evidence — 2026-09-09

- Family Ops / おうちノートの最上位成功条件は、technical completenessそのものではなく、canonical Requirements / approved UXどおりに家族の日常運営が続けられ、障害時にも家庭データを実際に復旧できることである。Lane CはRequest / Concierge / Today / LINE / PWAの利用者向け挙動を変更しない。
- Requirements & UX Baselineは「家庭で毎日使ったときに本当に回るか」を基準とし、LINEを日常の主導線、PWAを詳細・一括編集・設定・履歴等の補完とする。Lane Cのバックアップ/保護変更はこの主導線へ新しい操作や通知を追加しない。
- Fresh-read base `main` at the latest Lane C audit remained
  `6d93ba0d5b6ed1d6dbc3bbf8ec0a973f898d30ff` and unprotected.
- Lane C work is PR #68 on branch `sol/lane-c-operational-safety`. The exact
  CURRENT PR HEAD must be read from GitHub, not copied from this self-mutating
  status document.
- Latest verified predecessor HEAD before this status-only commit was
  `72d55475335304ad12e8388f66a35ddc8dfca74a`:
  - full CI `34315926902` / run #822 — Web, DB, Edge and real Supabase
    integration all SUCCESS;
  - Operational safety CI `34315926787` / run #28 — backup/restore controls
    and repository-enforcement verifier both SUCCESS.
  Re-run/fresh-read after any later source change; a stale GREEN is not release
  evidence for a different HEAD.
- `scripts/verify_repository_enforcement.sh` is the fail-closed CF-15 verifier.
  It accepts either a complete active ruleset or equally strong classic branch
  protection, and never combines incomplete controls into a synthetic PASS.
- CF-11 source hardening uses the same Supabase CLI version already proven by
  Family Ops real integration CI (`2.115.0`) and a Supabase-compatible logical
  bundle rather than a raw whole-cluster `pg_dump`. This is not a new product
  feature; it removes a recovery failure mode so the household can actually
  regain its application data in a fresh Supabase environment after a severe
  incident.
- The encrypted bundle contains application roles/schema/data plus migration
  history. The age private key remains outside GitHub/CI.
- Scheduled backup run `34275297279` on current `main` failed before dumping
  because `SUPABASE_DB_URL` was unset. The hardened PR workflow has therefore
  not yet produced runtime backup evidence.
- Freshness run `34288805536` was re-run on 2026-09-09 and still failed because
  the R2 account/access/secret/bucket inputs were absent.
- Supabase `family-ops` was independently read as `ACTIVE_HEALTHY`; the CF-11
  blocker is backup connectivity/credentials, not a stopped production DB.
- Production schema inspection confirmed the app relies on Supabase-managed
  `auth`/`storage`, Family Ops `public`/`private`, standard Supabase roles, and
  populated migration history. For that reason a plain vanilla PostgreSQL
  restore target is not treated as proof that Family Ops itself can recover.
- Vercel production remains the READY `main` deployment for
  `6d93ba0d5b6ed1d6dbc3bbf8ec0a973f898d30ff`; Lane C branch pushes have not
  produced new Preview deployments. This preserves the approved product UX
  while release enforcement is remediated.

The PASS authority for backup/recovery is `docs/BACKUP_RESTORE_RUNBOOK.md`.
The PASS authority for `main` release enforcement is
`docs/REPOSITORY_RELEASE_ENFORCEMENT.md`. A green source CI run or a production
HTTP 200 does not override RED operational evidence in this file.

## Verified LINE delivery evidence

The final production test selected the active linked recipient, created a
`public.user_notifications` row, created its outbox row through the trigger,
and explicitly invoked `send-notifications`. The recipient received the LINE
message on a real device. The quota audit then showed
`local_counted_success = 1`, a refreshed provider quota timestamp, and no
active quota reservation. The three minute cron jobs were all enabled and had
recent `succeeded` run records.

Earlier tests failed safely before push because the old access-token secret
contained header-invalid whitespace. The token was rotated; code now trims
surrounding whitespace and never returns raw header error text. Issue #2 is
closed only after the real-device delivery evidence above.

## Environment-name authority

For Edge Functions, the `Deno.env.get()` names in `supabase/functions` are the
source of truth. The template was aligned to use:

- `GOOGLE_CALENDAR_CLIENT_ID`
- `GOOGLE_CALENDAR_CLIENT_SECRET`
- `GOOGLE_CALENDAR_REDIRECT_URI`
- `GOOGLE_TOKEN_ENCRYPTION_KEY`
- `GOOGLE_CALENDAR_WEBHOOK_URL`
- `LINE_OA_BASIC_ID`

Geminiについては、現行の `Deno.env.get()` 呼び出しが読むのは
`GEMINI_API_KEY` と `GEMINI_MODEL_REWRITE` だけです。
`GEMINI_MODEL_PARSE` は現行実装では未使用のため、productionで設定済みでも
接続要件には含めません。

Never place server secrets (`SUPABASE_SERVICE_ROLE_KEY`, calendar client
secret, LINE secret/access token, Gemini key, `CRON_WORKER_TOKEN`, production
DB credentials, R2 secret access keys, or the backup age private key) in a
`VITE_*` variable or in repository content.

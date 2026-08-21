# Production connection status

Last audited: 2026-08-21 (Asia/Tokyo).  “Live test済” means a real provider
response was observed; a successful deployment or queue insert alone is not
treated as provider delivery.

| サービス | 接続元 | 接続先 | 必要secret | production設定済 | live test済 | 状態 | 残作業 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Vercel PWA | iPhone Safari | `family-ops-web.vercel.app` | `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` | 設定済（既存デプロイ） | 済 | 稼働中 | 自動デプロイSHAの定期確認 |
| Supabase Auth: Google Sign-In | PWA | Supabase Auth / Google | Supabase AuthのGoogle client ID/secret（VITEへは不要） | 未確認・有効化されていない実測あり | 失敗 | ブロック | Supabase DashboardでGoogle providerを有効化し、redirect URLを登録 |
| LINE webhook | LINE Developers | `line-webhook-receiver` | `LINE_CHANNEL_SECRET` | 設定済との既存確認 | Webhook verify成功（既存手動確認） | 受信側確認済 | Webhook URL / Use webhook ONを監査ワークフロー実行時に再確認 |
| LINE Messaging push | `send-notifications` | LINE Messaging API | `LINE_CHANNEL_ACCESS_TOKEN` | 値は非表示。利用可否は未確定 | 未達 | 安全停止 | quota safe-readの実際のHTTP結果を取得し、2xxのpushまでE2Eを通す（Issue #2） |
| LINE account link | PWA / inbox worker | `private.line_user_links` | `LINE_OA_BASIC_ID`（任意）, `CRON_WORKER_TOKEN` | active link 1件を実測 | 部分済 | 連携済 | 対象ユーザー/世帯一致を監査SQLで記録 |
| Supabase pg_cron / pg_net | pg_cron | LINE worker Edge Functions | `CRON_WORKER_TOKEN`（Vault） | cron設定workflow成功 | 未確認 | 要監査 | 3 jobの毎分登録と直近`cron.job_run_details`を直接確認 |
| GitHub Actions | manual dispatch | Supabase Management API | `SUPABASE_ACCESS_TOKEN` | 設定済（実行成功） | 部分済 | 稼働中 | E2E workflowが`outbox.status=sent`のみ成功にする |
| Google Calendar OAuth/API/watch | Calendar Edge Functions | Google Calendar API | `GOOGLE_CALENDAR_CLIENT_ID`, `GOOGLE_CALENDAR_CLIENT_SECRET`, `GOOGLE_CALENDAR_REDIRECT_URI`, `GOOGLE_TOKEN_ENCRYPTION_KEY`, `GOOGLE_CALENDAR_WEBHOOK_URL`, `APP_BASE_URL`, `CRON_WORKER_TOKEN` | 未設定として扱う | 未実施 | 後回し | Google Cloud OAuth client/API/consent screenと監視cronを設定後にE2E |
| Gemini | parse/rewrite Edge Functions | Gemini API | `GEMINI_API_KEY`, `GEMINI_MODEL_PARSE`, `GEMINI_MODEL_REWRITE` | 設定済との既存確認 | 未実施 | 要監査 | secretを出さずに最小実行でprovider応答を確認 |

## Current LINE delivery evidence

The production E2E test has proven all of the following: an active linked
recipient was selected, a `public.user_notifications` row was inserted, the
notification trigger created an outbox row, and `send-notifications` claimed
that row.  It has **not** proven LINE delivery.  The observed row was returned
to `fallback` with `last_error = provider quota data stale and refresh
unavailable`, `sent_at = null`, and no quota reservation.  Thus no push may be
claimed until a LINE API 2xx and `outbox.status = sent` are observed.

The manual `Send LINE notification test` workflow writes the asynchronous
worker response from `net._http_response`, quota state, and the final outbox
row before deciding success.  It is intentionally red when provider delivery
does not complete.

## Environment-name authority

For Edge Functions, the `Deno.env.get()` names in `supabase/functions` are the
source of truth.  The template was aligned to use:

- `GOOGLE_CALENDAR_CLIENT_ID`
- `GOOGLE_CALENDAR_CLIENT_SECRET`
- `GOOGLE_CALENDAR_REDIRECT_URI`
- `GOOGLE_TOKEN_ENCRYPTION_KEY`
- `GOOGLE_CALENDAR_WEBHOOK_URL`
- `LINE_OA_BASIC_ID`

Never place server secrets (`SUPABASE_SERVICE_ROLE_KEY`, calendar client
secret, LINE secret/access token, Gemini key, or `CRON_WORKER_TOKEN`) in a
`VITE_*` variable.

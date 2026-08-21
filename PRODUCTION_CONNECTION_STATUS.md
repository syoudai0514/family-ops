# Production connection status

Last audited: 2026-08-21 (Asia/Tokyo).  “Live test済” means a real provider
response was observed; a successful deployment or queue insert alone is not
treated as provider delivery.

| サービス | 接続元 | 接続先 | 必要secret | production設定済 | live test済 | 状態 | 残作業 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Vercel PWA | iPhone Safari | `family-ops-web.vercel.app` | `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` | 設定済（既存デプロイ） | 済 | 稼働中 | 自動デプロイSHAの定期確認 |
| Supabase Auth: Google Sign-In | PWA | Supabase Auth / Google | Supabase AuthのGoogle client ID/secret（VITEへは不要） | 未確認・有効化されていない実測あり | 失敗 | ブロック | Supabase DashboardでGoogle providerを有効化し、redirect URLを登録 |
| LINE webhook | LINE Developers | `line-webhook-receiver` | `LINE_CHANNEL_SECRET` | 設定済との既存確認 | Webhook verify成功（既存手動確認） | 受信側確認済 | Webhook URL / Use webhook ONを監査ワークフロー実行時に再確認 |
| LINE Messaging push | `send-notifications` | LINE Messaging API | `LINE_CHANNEL_ACCESS_TOKEN` | 設定済・新tokenへ更新済 | 済（実端末受信、outbox成功1件） | 稼働中 | tokenをログへ出さない運用を継続 |
| LINE account link | PWA / inbox worker | `private.line_user_links` | `LINE_OA_BASIC_ID`（任意）, `CRON_WORKER_TOKEN` | active link 1件・世帯/設定整合1件 | 済 | 稼働中 | `LINE_OA_BASIC_ID` を設定すればワンタップ連携（Issue #5） |
| Supabase pg_cron / pg_net | pg_cron | LINE worker Edge Functions | `CRON_WORKER_TOKEN`（Vault） | 3 jobとも有効・毎分 | 済（直近run成功） | 稼働中 | 定期監視を将来追加 |
| GitHub Actions | manual dispatch | Supabase Management API | `SUPABASE_ACCESS_TOKEN` | 設定済（実行成功） | 済 | 稼働中 | E2E workflowが`outbox.status=sent`のみ成功にする |
| Google Calendar OAuth/API/watch | Calendar Edge Functions | Google Calendar API | `GOOGLE_CALENDAR_CLIENT_ID`, `GOOGLE_CALENDAR_CLIENT_SECRET`, `GOOGLE_CALENDAR_REDIRECT_URI`, `GOOGLE_TOKEN_ENCRYPTION_KEY`, `GOOGLE_CALENDAR_WEBHOOK_URL`, `APP_BASE_URL`, `CRON_WORKER_TOKEN` | 未設定として扱う | 未実施 | 後回し | Google Cloud OAuth client/API/consent screenと監視cronを設定後にE2E |
| Gemini | `propose-ai-draft` Edge Function | Gemini API | `GEMINI_API_KEY`, `GEMINI_MODEL_REWRITE` | 設定済との既存確認 | 未実施 | 要監査 | PWAのAI言い換えでprovider応答を確認 |

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
source of truth.  The template was aligned to use:

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
secret, LINE secret/access token, Gemini key, or `CRON_WORKER_TOKEN`) in a
`VITE_*` variable.

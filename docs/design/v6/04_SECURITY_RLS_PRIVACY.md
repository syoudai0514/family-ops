# 04. Security / RLS / Privacy — v6 normative

## 1. Security objective

夫婦2人用でも「URL/UUIDを知れば相手家庭のデータを触れる」「client payloadでactorを偽装できる」「private raw textがpartnerへ漏れる」を許さない。

## 2. Identity

Canonical membership=`public.household_members`。

- PWA: Supabase JWT `sub`
- LINE: verified LINE user ID -> server-side linked Family Ops user
- Cron: `CRON_WORKER_TOKEN`
- Google webhook: channel ID/resource ID/channel token

`actor_id`/`household_id`をclient JSONから認可に使わない。

## 3. Public read

All public household tables RLS enabled。

基本helper:
- caller is member of row household
- recipient-only tableはrecipient=selfまで絞る

Profilesはselfまたはsame-household memberのみ。

## 4. Public mutation

Authenticated browser:
- SELECT: explicit grants + RLS
- INSERT/UPDATE/DELETE: stateful business tablesはREVOKE

PWA mutation:
- Edge Function only
- Edge validates user/household/resource
- server-only tx RPC

## 5. Function execute grants

Migrationで必須:

```text
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
```

User-facing read helperだけ必要最小限GRANT。
Transaction RPCはserver roleだけ。

SECURITY DEFINER helper:
- only if unavoidable
- `SET search_path=''`
- every reference schema-qualified
- dynamic SQL禁止 unless hard validated

## 6. Private schema

- `REVOKE ALL ON SCHEMA private FROM PUBLIC,anon,authenticated`
- current/future tables, sequences, functions default revoke
- Data API public exposure不可

Contains:
- private raw input
- encrypted Google token
- LINE link/invite token hashes
- queues
- sync/write operation state
- mutation receipts
- scheduled dispatch receipts

## 7. Same-household DB guarantees

Application authorizationだけでなくFK/triggerで拒否する。

Required composite constraints:
- task assignees/completers/creator
- subtask completed_by
- request requester/recipient
- handover author/read user
- shopping assignee/creator
- notification recipient
- calendar mapped creator/busy member
- google connection owner
- calendar connection -> google connection

Cross-household service-side INSERTもDBが失敗するtestを持つ。

## 8. Immutable ownership

Direct client writeをREVOKEした上で、transaction APIも以下のownership fieldを変更しない。
- household_id
- created_by
- requester_id
- recipient_id after request create
- author_id
- calendar_connection_id on cached resources

## 9. Raw partner text

`private.raw_inputs`。
RecipientはRLS以前にData API access不可。

Shared request/handoverにはAI変換後・本人確認済みtextのみ。
AI failure時にrawをshared fallbackしない。

ユーザー方針によりAI privacyそのものはrelease blockerにしないが、secret/token/payment credential等のbasic guardは残す。

## 10. Cron secret

- `CRON_WORKER_TOKEN` 256-bit
- constant-time verify
- secret never returned to PWA
- logs redact worker header
- wrong/missing=401

## 11. LINE security

Inbound:
- signature validation before durable inbox insert
- webhookEventId dedup

Link:
- raw token only once to user
- SHA-256 token hash in DB
- 10m TTL
- single-use transaction claim
- expired/used hard delete by cleanup after audit window specified in DDL

Postback:
- LINE actor derived from linked account
- arbitrary user_id in postback ignored

## 12. Google credential

`private.google_connections` includes household_id and owner_user_id.

Composite FK:
`(household_id,owner_user_id) -> household_members`

`public.calendar_connections` composite references `(household_id,google_connection_id)`.

Refresh token:
- AES-256-GCM envelope
- key in Edge secret
- no browser exposure
- DB dump contains ciphertext only

## 13. Scheduled check-in privacy

- session row same household read allowed, but mutation actor rules enforced by Edge
- PWA deep link contains session UUID only, no bearer secret
- login required
- partner may see shared task status; private raw text never appears
- LINE scheduled payload contains only shared task titles/assignments, not raw AI input

## 14. RLS acceptance

Use `fixtures/RLS_POLICY_MATRIX.md` and automated SQL tests.
Minimum:
- household A cannot select/mutate B resources
- partner cannot read private raw input
- anon cannot execute tx RPC
- authenticated cannot directly execute server tx RPC
- Edge valid flow succeeds
- same-household composite violations fail at DB level

## v6 RPC transport

- private schemaはExposed Schemasへ追加しない。
- Edgeが呼ぶatomic entrypointは`public.server_tx_*`のみ。
- `PUBLIC`, `anon`, `authenticated`からEXECUTEをREVOKE。
- `service_role`だけEXECUTEをGRANT。
- functionはSECURITY INVOKER。
- service_roleにprivate schema USAGEと必要テーブルDMLを明示GRANT。
- browserから`supabase.rpc('server_tx_*')`を直接呼んでもpermission deniedであることをCIでassert。

## v6 account deletion policy

MVPはauth user / household member hard deleteをサポートしない。
historical FKがRESTRICTするため、Supabase Dashboardからauth userを直接削除しないことをrunbookに明記する。
将来の退会/削除は別設計でanonymize/soft lifecycleを実装してから行う。

## v6 LINE identity trust boundary

- LINE actorは署名検証済みWebhookの`source.userId`だけを入力にする。
- postback data、message text、client payloadに含まれるuser idをactor認証へ使わない。
- active `private.line_user_links`にmappingが無いsource.userIdはmutation不可。


## v6 Edge gateway requirement

`EDGE_FUNCTION_AUTH_MATRIX.md` + `supabase/config.toml` are part of security contract.
verify_jwt=false does not mean trusted/public; provider/worker auth happens before DB access.


## v6 calendar classification RLS

- parent/member SELECT only same household
- direct browser mutations denied
- normalized child member composite FK enforces household integrity
- partial unique prevents duplicate NULL series default

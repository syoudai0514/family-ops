# Issue #48 — Five-HIGH independent re-review closeout

This addendum supersedes the evidence rows for **Q50 / Q59 / Q64 / Q110 / Q111** in `ISSUE-48-Q1-Q112-CONFORMANCE-MATRIX.md` for the post-review remediation head. The other 107 Q rows remain unchanged from the zero-base matrix and the second independent review already assessed those 107 as PASS.

The acceptance authority remains `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` Appendix A, then `docs/design/current/`, Accepted ADRs, and CURRENT source/schema/tests.

## Safety boundary

No main merge, production deployment/mutation, production Supabase mutation, real LINE send, LINE provider mutation, or Google provider mutation occurred in this remediation. H6-B real LINE transcript remains a post-source-GO release gate.

## Remediation evidence

| Q | Literal requirement | CURRENT implementation | Direct test evidence | Real-use scenario | Result |
|---|---|---|---|---|---|
| Q50 | ルール由来未来予定だけ再計算。個別合意は維持確認を双方へ。 | `20260906000002_issue48_five_high_remediation.sql` + `20260906000003_issue48_five_high_hardening.sql`; durable `transport_conflict_review_groups/items/responses`; `TransportTemplateEditor.tsx`. First response never resolves; both users must answer. Both keep => `kept`; any review => original agreement remains and Q51 state becomes `担当調整中`. | `75_issue48_q50_q110_q111_literal_regression.sql`; `TransportTemplateEditor.test.tsx` | 曜日ルールを変更しても個別合意済みの送り迎えはそのまま残り、パパ・ママ双方へ「維持する / 見直す」を確認。1人目が見直しでも即変更せず、2人目回答後に担当調整中へ進む。 | PASS |
| Q59 | 一括完了は即確定し、直後に例外修正/undo。 | `routine_reconciliation_operations/snapshots`; `server_tx_reconcile_routine_session_v2`; `server_tx_undo_routine_reconciliation`; unchanged-snapshot pruning; `CheckinPage.tsx` immediate `例外を修正` / `元に戻す`. Undo uses exact receipt scope and task revision/status CAS. | `76_issue48_q59_q64_literal_regression.sql`; Checkin Web tests | 「全部やった」で即記録し、その直後に例外修正または元に戻せる。完了後に1件でも別更新された場合、古い一括undoは全体をfail-closedして後更新を巻き戻さない。 | PASS |
| Q64 | 個別回答で 完了 / 相手が対応 / できなかった / 今回不要 / 中止 / 再予定 / 不明 を区別する。 | `server_tx_routine_session_item_action_v3`; `routine_item_reconciliation_outcomes`; Q64 outcome reasons + `rescheduled_to`; `CheckinPage.tsx`; `process-line-inbox/index.ts`; `routineItemFlow.ts`. PWA/LINE both enter the same v3 canonical command. `unknown` remains distinct and follows carryover policy. | `76_issue48_q59_q64_literal_regression.sql`; `routineItemFlow.test.ts`; Checkin tests; Edge CI | 夜まとめで7種類を別々に入力でき、LINEから入力してもPWAと同じcanonical truthになる。「できなかった」を「今回は不要」に潰さず、「不明」も独立証跡として残す。 | PASS |
| Q110 | Google日時変更は予定へ反映し、関連準備は変更候補。 | `event_preparation_change_candidates`; Google review resolver; external-follow prep candidate trigger; `GoogleEventReviewPage.tsx`. Incomplete linked prep (`task_instances.event_id`) gets a reviewable proposal; completed actuals are excluded; prep is never auto-shifted. | `75_issue48_q50_q110_q111_literal_regression.sql`; `73_google_human_confirmed_diff_review.sql`; `GoogleEventReviewPage.test.tsx` | Googleの面談日時を翌日に変更し、人が予定変更を反映すると、未完了の持ち物準備は「現在 / 変更候補」で確認できる。提出済み準備は変わらない。 | PASS |
| Q111 | Google削除は 中止 / 日程変更待ち / Googleのみ非表示 を確認。 | `family_events.schedule_review_state`; extended Google review resolution; `GoogleEventReviewPage.tsx` exact three actions. `cancel_family` cancels Family Ops event; `waiting_reschedule` keeps it active in waiting state; `google_only_hidden` keeps Family Ops truth and detaches only Google link. | `75_issue48_q50_q110_q111_literal_regression.sql`; `GoogleEventReviewPage.test.tsx` | Googleから予定が消えても自動削除せず、家庭予定を中止するか、日程変更待ちにするか、Google側だけ非表示にするかを選ぶ。 | PASS |

## Q64 channel parity

LINE item-by-item postbacks now support all seven semantic outcomes through `server_tx_routine_session_item_action_v3`. `routineItemFlow.ts` exposes the seven actions plus `次へ`; the worker records `source='line'`, while PWA records `source='pwa'`, into the same `routine_item_reconciliation_outcomes` model. The direct SQL regression deliberately mixes three LINE and four PWA answers and asserts all seven distinct outcomes.

## Q59 concurrency/undo boundary

Bulk completion creates a durable operation receipt and snapshots only eligible rows. The hardening trigger removes rows whose before/after state is identical. Undo first locks and validates every retained task against its exact post-operation revision and status; if any task changed later it raises `RECONCILIATION_UNDO_STALE` before restoring anything. The direct regression verifies both successful exact undo and all-or-nothing stale rejection.

## Q50 Q51 boundary

A transport review group remains `pending` until the number of distinct household responses reaches the number of household members. A first `review` response does not resolve it. After both responses, all-keep resolves `kept`; otherwise it resolves `needs_review`, emits `transport_conflict_adjusting` to both users, returns `q51_state='担当調整中'`, and never rewrites the protected task agreement.

## H6 / release gate

- H6-A source/runtime coherence: remains PASS; LINE worker changes are covered by Edge lint/typecheck/unit/auth-matrix CI and the existing LINE suite.
- H6-B real LINE transcript: **not executed by design** before independent source GO.

## Finalization

The final exact head and exact-head 4/4 CI run are recorded in PR #50 body after this addendum commit and the final CI complete. At that exact reviewed head the intended closeout count is:

- PASS: 112
- GAP: 0
- USER_DECISION_REQUIRED: 0
- external release gate: H6-B only

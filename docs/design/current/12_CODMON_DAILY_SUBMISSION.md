# 12. Codmon Daily Submission

- **Status:** CURRENT detailed design
- **Authority:** Requirements Baseline §19.18 / Q113
- **Scope:** daily Codmon contact-book coordination only; nursery notice/image intake remains in the existing Q89-Q106 flow.

## 1. Product boundary

おうちノートはコドモンの入力フォームを複製しない。夕食内容、体調、朝食等の具体値をFamily Opsへ再入力・保存させると、二重入力・privacy拡大・source-of-truth競合になるためである。

Family Opsが持つtruthは次だけ。

- その日のCodmon入力項目を誰が担当するか
- その担当がCodmon側で入力を済ませたか
- 必要入力が全て揃ったか
- 人がCodmon上で最終送信したことを確認したか
- deadline / reminder / audit

Codmon providerへの自動送信・画面自動操作はこのscopeに含めない。

## 2. Daily task contract

| task code | 表示 | 担当 | deadline |
|---|---|---|---|
| `codmon_masaki_pickup_input` | 将生：迎えの人・時間。Codmonにプール欄がある日は可否も入力 | 当日pickup担当 | 09:15 |
| `codmon_shino_previous_input` | 詩乃：昨日の夕飯・様子 | 前日担当 | 09:15 |
| `codmon_shino_breakfast_input` | 詩乃：朝食 | 当日朝担当 (= 現行dropoff担当) | 09:15 |
| `codmon_shino_pickup_input` | 詩乃：迎え | 当日pickup担当 | 09:15 |
| `codmon_submit` | 将生・詩乃の入力を確認してCodmon送信 | 当日朝担当 | 09:15 |

いずれも普通のToday taskとして扱い、追加のdashboardを作らない。

## 3. Previous-day owner resolution

`previous_evening_assignee` は以下の順で解決する。

1. 前日のpickup occurrenceがperson assignmentなら、実績担当 (`actual_completed_by_id`) を優先し、無ければ最終planned assigneeを使う。
2. pickupが無い場合、前日の通常evening task群からperson ownerを集める。
3. adultが1人に一意ならその人。
4. 0人または複数人なら `unassigned`。推測しない。

このstrategyはfutureを先行materializeしない。daily materializerのrangeがtoday..+14でも、その日のownerはその日になってから作る。

## 4. Nonworkday

`private.fn_is_nonworkday` がtrueの土日・日本祝日はCodmon taskをmaterializeしない。例外的な登園日に必要なら、将来は明示overrideとして扱い、通常休日を自動提出日にしない。

## 5. Readiness / final-send invariant

`codmon_submit` をcompletedへ遷移させる前に、同一household / same scheduled_date / same test-contextの4 input task codeが全てcompletedであることをDB boundaryで検証する。

1つでも未完了/欠落なら `CODMON_INPUTS_INCOMPLETE` (409)。PWAは「残っている入力を先に完了」と表示する。

UIだけのdisabled制御には依存しない。LINE / PWA / routine-session / future command pathのどこからcompleteされても同じDB invariantを通す。

### 5.1 Shared readiness projection

Codmon readinessは `private.fn_codmon_readiness_v1` の1つの投影を基準にし、
DailyBrief / LINE Today / final-submit guard / 09:00 reminderで別々に推測しない。

状態は次の5つ。

- `not_applicable`: Codmon未設定、または通常提出対象でない日。
- `data_incomplete`: 提出対象日だが、固定4 input または submit task が欠落/重複しており安全に判断できない。
- `waiting_inputs`: 必要行は一意に存在するが、4 input のいずれかが未完了。
- `ready_to_submit`: 4 input がすべてcompletedで、submit taskが未完了。
- `acknowledged`: 人がCodmonで送信した事実をFamily Ops上で完了申告済み。後からinputを訂正しても、この送信履歴を自動で巻き戻さない。

投影は少なくとも `local_date`, `deadline_at`, `submit_task_id`,
`input_completed_count`, `required_input_count=4`, inputごとの
`code/task_id/title/assignee/status/resolution`、submit担当を返す。
inputの `resolution` は `present | missing | duplicate` とし、欠落/重複を
“未完了0件”としてready扱いしない。deadlineはsubmit taskの `due_at` を
優先し、必要時だけ09:15 JSTをfallbackにする。

Todayでは別dashboardを増やさず `codmon_submit` 行へ残入力と担当をinline表示する。
`ready_to_submit` までは通常の完了操作を無効化し、ready時の申告は
「コドモンで送信した」とする。この操作はproviderを送信するbuttonではなく、
外部Codmon上で人が実際に送信した後のacknowledgementである。

## 6. Reminder

09:00 JST時点で`codmon_submit`が未完了なら1回評価する。

- adultごとに、自分へ割り当てられた未完了inputだけを1通にまとめる。
- assigneeが解決できないinputは、両adultへ `担当未定` として同じ通知内に示す。
- 4 inputが既に揃っている場合は、submit担当へ `9:15までに送信` を通知する。
- dedup keyは household + adult + local_date。09:00 worker retryで重複しない。
- business expiryは09:15 JST。
- LINE bridgeは既存 `routine_checkin_prompt_line` preference / link / quota safetyを再利用する。LINEに出せない場合でもToday/in-app truthは残る。

09:10等の追加定時pushは既定では持たない。朝DailyBrief + Today deadline + 09:00 targeted reminderでまず運用し、実利用証跡で不足時だけ追加する。

## 7. Privacy / provider authority

- Family OpsにはCodmonフォーム回答本文を保存しない。
- Family Opsのcompleteは `Codmonで入力した` / `Codmonで送信した` という家庭運用のacknowledgement。
- provider送信成功を自動で主張しない。
- 将来Provider API等を追加する場合は別requirements/design/approvalを要する。

## 8. Physical acceptance

最低限、実家庭で以下を確認する。

1. 平日朝に5 taskが生成され、09:15が見える。
2. 将生 pickup input / 詩乃 pickup inputが当日pickup担当へ付く。
3. 詩乃朝食とfinal submitが朝/dropoff担当へ付く。
4. 詩乃昨日夕飯・様子が前日担当へ付く。
5. input未完了ではfinal submitを完了できない。
6. 4 input完了後はfinal submitを1tap完了できる。
7. 09:00残件notificationが担当別にまとまり、同じminute retryで重複しない。
8. 土日祝に通常task/reminderが出ない。

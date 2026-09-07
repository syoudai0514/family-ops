# Issue #54 — Gate C real iPhone user acceptance evidence

Status: **PENDING FOR RELEASE ACCEPTANCE / NOT YET EXECUTED**.

The previous version of this document incorrectly treated mobile CSS, jsdom/component tests, and CI as equivalent to Gate C. Issue #54 requires **real iPhone user acceptance using actual user scenarios, not component inspection**. Those deterministic checks remain useful Gate A evidence, but they do not satisfy Gate C.

The independent review NO-GO at exact head `2f37e257b15f077940de27ef3821d7a4097b2e54` correctly identified that gap. Source remediation may be independently re-reviewed before Gate C; physical Gate C remains mandatory before final release/merge approval.

## Sequencing

- **Independent source re-review:** may proceed now after source remediation + full CI. Gate C is not a blocker to reviewing source parity.
- **Release acceptance:** cannot be GO until the physical iPhone scenarios below are executed and recorded against an exact tested head.
- No source review result may be misrepresented as physical Gate C evidence.

## Safety constraints

The real-iPhone pass must remain inside the release safety boundary:

- no main merge before final release GO;
- no production deployment/mutation performed as part of pre-GO validation unless explicitly authorized for the release step;
- no real LINE send/provider mutation during the safe Gate C scenarios;
- no Google provider mutation during the safe Gate C scenarios;
- use safe/test-mode or an explicitly authorized release-candidate surface when Gate C is executed.

## Required real-iPhone scenarios

Gate C is PASS only after the following are physically exercised on an iPhone and the observed results are recorded against one exact tested head.

| Scenario | Required physical interaction and acceptance evidence |
|---|---|
| Today first viewport | Open Today on iPhone. Confirm `最初にここだけ見ればOK` and four meaning labels (`返事・担当未定`, `今日の自分タスク`, `待ち・あとで確認`, `明日の予定・準備`) are readable without relying on component source. Tap each relevant shortcut and verify navigation/scroll target. |
| Check-in bulk scope | Open an active check-in. Immediately above `全部やった`, verify the concrete included names are visible (e.g. `洗濯：畳む`, `明日の着替え準備`) and optional/excluded names (e.g. `フィルター掃除`) are visibly separated. Do not perform an unsafe external-provider mutation. |
| Concierge / Transcript correction | Enter or dictate `金曜のお迎えママお願い……あ、やっぱ土曜。牛乳も買って。`. Verify Results contains a Saturday pickup/request assigned to Mama plus a separate milk shopping candidate, with no stale Friday candidate. |
| Results edit | On the same Results screen, tap `編集`, change a candidate field, save it, and verify the changed candidate is what proceeds to confirmation. |
| Back/state | Return/back through the exercised flows and verify draft/filter/selection/scroll state is preserved where the contract specifies it. |
| Existing safe high-risk paths | Spot-check Requests response, History correction, Month/day agenda, LINE reference deep-link, and Google/Nursery review surfaces without real LINE/Google provider mutation. |

## Deterministic support evidence (not Gate C by itself)

The following supports source re-review and the later physical run but cannot replace Gate C:

- mobile/iOS source behavior in `apps/web/src/mobileHotfix.css` and `apps/web/src/App.css`;
- Web lint/typecheck/test/build;
- Edge lint/typecheck/unit/auth-matrix;
- DB migrations/regression suite;
- real Supabase CLI stack;
- targeted regressions for Check-in named bulk scope, Today labels, Concierge correction parsing, Results editing, and canonical request payload/date preservation;
- CI #719 on remediation implementation head `8b66598cd942cb4cdc5dfcd2eb7624e46b8bf51f` — FULL GREEN;
- CI #720 on remediation verification head `2e2782a27e6bf448b5d3c167a00754927e0ab008` — FULL GREEN.

## Recording rule

After the real iPhone run, update this document with:

1. exact PR head exercised;
2. date/time and device/browser/PWA mode;
3. each scenario PASS/FAIL with the visible result;
4. any failure reproduction steps;
5. confirmation that no prohibited provider mutation occurred.

Until that evidence exists, **Gate C remains pending and final release/merge remains NO-GO**, even if targeted independent source re-review is GO.

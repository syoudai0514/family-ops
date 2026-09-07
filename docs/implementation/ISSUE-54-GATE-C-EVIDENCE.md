# Issue #54 — Gate C iPhone-equivalent evidence

Status: PASS for safe pre-review evidence at PR #56 head `dbcb08ef822158b65bd5698babc79dd8e3101588`.

## Scope and safety

Gate C proves the approved final-v11 UX contract through real-use-equivalent interaction evidence without any prohibited external mutation.

- iPhone-equivalent target: mobile layout `max-width: 899px`, iOS safe-area guards, fixed bottom navigation, touch targets >= 44px.
- No production deployment.
- No production Supabase mutation.
- No real LINE send/provider mutation.
- No Google provider mutation.
- Canonical truth is proven by the same DB/Edge paths executed in CI #702 real-stack tests.

## Evidence chain

| Scenario | Entry | Operation | Result | Canonical truth | Return/state |
|---|---|---|---|---|---|
| Today / Check-in | `/today` -> `/checkin` | bulk/individual outcomes | receipt-scoped result and correction | DB suites incl. Issue #54 Check-in regression; CI #702 DB + real CLI GREEN | mounted route/back-state regressions |
| Task create/edit | Quick Add -> task modal | create/edit + subtasks | canonical task appears in Today | Web task form regressions + CI #702 Web GREEN | session draft and modal return-state regressions |
| Request create/respond | `/requests?bucket=active` | send with distinct reply/work deadlines; accept/decline/consult | state transition and recipient/sender view | `server_tx_send_request_v2`, `request_attempts.reply_due_at`; DB/real-stack CI #702 GREEN | URL bucket retained; response refresh restores scroll; Web regression GREEN |
| Concierge | `/concierge` -> results -> confirm | multi-intent select/clarify/confirm | per-candidate success/failure | canonical command mappings + Edge/DB regressions | input preserved; failed-only retry preserves successful results |
| History correction | `/history` | correction | visible scheduled-date truth updated while audit remains collapsed | History deterministic tests + DB suites | filter/selected row/scroll state retained |
| Month/day agenda | `/month` -> selected day agenda | open detail/edit | updated canonical item reflected | Month/DayAgenda regressions | selected date preserved on return |
| LINE reference | `/settings/line-reference` | six fixed entry deep links | PWA destination only | same canonical PWA surfaces; no provider mutation | navigation-only safe evidence |
| Google/Nursery review | review screens | inspect/resolve protected diffs/duplicates | local canonical review decisions only | provider fences and DB/Edge tests GREEN | no external provider write performed |
| Transcript | `/concierge/transcript` | `ja-JP` browser speech transcript remains editable | same proposal/confirm flow as text | deterministic transcript/Concierge source contract | mobile WebKit-compatible browser API path; no provider mutation |

## Mobile-equivalent source evidence

`apps/web/src/mobileHotfix.css` and `apps/web/src/App.css` enforce mobile/iOS behavior used by the above flows: `100dvh`, safe-area bottom padding, fixed bottom nav, touch-action manipulation, overflow guards, and >=44px controls at mobile width.

## CI evidence

CI #702 for exact head `dbcb08ef822158b65bd5698babc79dd8e3101588` is FULL GREEN:

- Web lint: SUCCESS
- Web typecheck: SUCCESS
- Web tests: SUCCESS
- Web build: SUCCESS
- Edge lint/typecheck/unit/auth-matrix: SUCCESS
- DB migrations + SQL regression suite: SUCCESS
- Real Supabase CLI stack: SUCCESS, including reset/apply-all-migrations and real-stack integration tests

This evidence is equivalent pre-review evidence, not production validation. Production, real LINE, and Google mutation remain explicitly prohibited until independent review GO.

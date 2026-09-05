# おうちコンシェルジュ / 実績入力 UX Prototype v2 — Implementation Handoff

## Status

This is a design/implementation handoff, not production code. It is intended to reproduce the approved UX with high fidelity in the current React PWA while preserving canonical authority/state rules.

## Key UX decisions

### 1. Two entry modes coexist

- Existing purpose-specific input remains: Event, ToDo, Request, Shopping, Handover, Routine, Morning preparation.
- Add `おうちコンシェルジュ` as the first item in Quick Add and as a light entry on Today.
- Concierge supports free text and voice-to-text. Realtime voice conversation is not required.
- LINE text, PWA free text and PWA voice transcript must converge on the same semantic interpretation/candidate layer.

### 2. Daily actual input is optimized for the normal case

Night/next-morning group input starts with exactly:

- `全部やった`
- `大体やった`
- `個別で答える`

`全部やった` is one-tap confirmation for the ordinary case; do not insert a confirmation screen every day. After recording, offer reversible `例外を修正` / `元に戻す` affordances.

`大体やった` records group-level reconciliation evidence only and must not silently mark unknown child tasks complete or failed.

### 3. Individual actual input

Normal item row exposes one primary action only:

- `完了`

Rare outcomes are hidden under `その他の結果`:

- `相手が対応`
- `できなかった`
- `今回は不要`
- `中止になった`
- `別の日にやる（再予定）`

The purpose is: normal case = one tap, rare case = one extra disclosure.

### 4. Actual date/time semantics

Do not ask the user to manage actual completion time.

- The actual is linked to the task occurrence/target date.
- If entered the next morning, it still belongs to the original task date.
- Registration timestamp and correction timestamp remain audit metadata.
- Normal History UI should show e.g. `実績: 9/5 · パパ`, not imply `20:31` was the actual work time.
- Audit timestamp may be visible only in an expanded audit/details affordance.

### 5. History

Normal row:

- title
- outcome
- planned date/time + planned assignee
- actual target date + actual participant(s)
- `実績を訂正`

Collapsed by default:

- registration timestamp
- correction history

Never convert no input into `できなかった`.

## Prototype implementation fidelity

Treat the prototype as a high-fidelity UX contract for layout, hierarchy, copy, visible states and interaction order. It is **not** copy-paste production code because it uses static/demo data and omits real auth/API/state-machine/concurrency plumbing.

Production implementation should reuse current components and commands rather than replace them with prototype HTML. Recommended mapping:

- Today card/entry -> current `Today.tsx`
- Quick Add first item -> current `QuickAdd.tsx`
- group actual input -> current `CheckinPage.tsx`
- individual actual outcomes -> current check-in item actions, expanded to canonical exception outcomes
- history semantics -> current `HistoryPage.tsx`
- concierge shell -> new PWA surface backed by shared semantic interpretation layer

A correct implementation should look very close to the prototype while retaining current canonical command/state/authority/idempotency behavior.

## Acceptance focus

- iPhone normal case can complete daily actual input in one tap after opening the current input.
- Individual mode does not expose rare-case complexity until requested.
- next-morning entry binds to original target date.
- registration time is not presented as work-completion time.
- no-input remains unknown, not failed.
- Today/current-input/History stay in-place without full-page reload or scroll reset.
- Concierge does not replace purpose-specific forms.

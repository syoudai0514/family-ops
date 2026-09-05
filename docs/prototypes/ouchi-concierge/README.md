# おうちコンシェルジュ UX prototype

Design-only interactive prototype for Family Ops / おうちノート.

## Purpose

- Preserve the CURRENT PWA information architecture and existing purpose-specific entry points.
- Add `おうちコンシェルジュ` as an additional free-input entrance.
- Support text input and transcription-first voice input.
- Reuse the same semantic model across LINE and PWA conceptually: household context, household terminology, multi-intent decomposition, ambiguity detection, candidate generation, authority/safety checks, and explicit confirmation.
- Keep deterministic explicit actions deterministic; do not route every click through AI.

## CURRENT baseline used for this prototype

Prototype baseline was fresh-read from PR #50, branch `impl/issue-48-ux-closeout`, around head `364c0203c8e2c067769cbfb9a9629061c2ca89ed` on 2026-09-05. The implementation branch is active, so source always remains authoritative.

CURRENT primary navigation reflected here:

- 今日
- 週
- 月
- 買い物
- 履歴
- ＋

Existing Quick Add items remain present. `おうちコンシェルジュ` is added above them rather than replacing them.

## Included prototype flows

- Today long state with shortcuts, current check-in, pending reply, next action, schedule, morning/evening work, partner-critical item, shopping summary
- Week
- Month + day agenda sheet
- Quick Add
- Event / schedule form
- Requests
- Shopping
- Handovers
- History
- Check-in
- Settings
- Nursery notice review / provenance example
- Ouchi Concierge free text
- Voice recording / transcription-first flow
- AI candidate review
- Candidate edit
- Registration success

## Run

Open `index.html` in a browser. No build step is required.

This is a design artifact only. It does not call production APIs, send LINE messages, mutate Google Calendar, apply migrations, or change production data.

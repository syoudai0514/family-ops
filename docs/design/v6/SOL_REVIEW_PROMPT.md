# GPT-5.6 Sol v6 independent review

Review `family-ops-sonnet-plan-v6` without implementation.

Previous v5:
REQUEST CHANGES / P0 0 / P1 8 / P2 8 / P3 2.

Read:
1. review/FAMILY_OPS_V5_SOL_REREVIEW_2026-08-19.md
2. 16_REVIEW_DISPOSITION.md
3. V6_CHANGELOG.md
4. V6_SELF_CHECK.md
5. EDGE_FUNCTION_AUTH_MATRIX.md
6. supabase/config.toml

Mandatory:
- verify all 8 prior P1 closed
- Edge auth/config exact
- recurring identity stable
- normalized busy classification/RLS/FK
- evening fresh setup
- LINE retry expiry/delivery_unknown
- atomic cap=200 under concurrency/provider-plan change
- Google accessRole/timezone/PATCH preservation
- DDL provider_event_id consistency

Also verify:
- 429 monthly vs transient
- durable notification history
- A→B→A generation
- one scheduled dispatch unique
- R2 Standard
- Edge invocation free telemetry
- weekend/holiday rule:
  - non-holiday weekdays use role routine
  - Sat/Sun/public holiday use 09:00 + 20:00 only
  - Sunday 09:00 includes next week
  - no Sunday 12:00
  - both linked normal max 4 counted/day
  - official holiday fixture/source deterministic

Fixtures:
EDGE_AUTH_CASES, GOOGLE_RECURRENCE_IDENTITY_CASES, GOOGLE_WRITE_CASES,
LINE_RETRY_CASES, LINE_QUOTA_ATOMIC_CASES, EVENING_SETUP_CASES,
NONWORKDAY_SCHEDULE_CASES, RLS matrices, existing queue/idempotency cases.

AI privacy is not a standalone blocker per user decision.

Output:
PASS or REQUEST CHANGES
P0/P1/P2/P3
each finding file/section + scenario + exact fix + acceptance
WP0 GO/HOLD
WP1 GO/HOLD
whether Sonnet can implement without inventing semantics.

Target P0=0/P1=0.

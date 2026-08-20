# V5 SELF CHECK

## Release gate target
- P0 target: 0
- P1 target: 0
- WP0: GO
- WP1: HOLD until independent SOL returns P0=0/P1=0

## Checklist
- [x] No `private.tx_*` required over Data API.
- [x] public server transaction RPC is service_role-only.
- [x] private schema remains non-exposed.
- [x] LINE monthly limit cannot silently become a paid-overage path.
- [x] Reminder fallback begins at soft budget.
- [x] Valid interactive reply path avoids counted push where possible.
- [x] LINE user identity has permanent mapping.
- [x] Missing queue/token schemas are exact.
- [x] Household join has 2-adult concurrency guard.
- [x] OAuth state is hash-only/single-use/10m.
- [x] Calendar initial/incremental/projection parameters are fixed.
- [x] 410 staging is exact and atomic.
- [x] No local recurrence parser.
- [x] Cross-household busy-member FK closed.
- [x] Asia/Tokyo fixed.
- [x] Backup health source ambiguity removed.
- [x] Retentions fixed.
- [x] Same-day schedule edit cannot double-send.
- [x] AI privacy remains non-blocking per user decision.

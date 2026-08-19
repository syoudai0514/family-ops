# Claude Code Sonnet implementation request — v6

Use family-ops-sonnet-plan-v6 only.
Do not implement from v1-v5.

Gate:
- WP0 may start.
- WP1 MUST wait for independent v6 SOL P0=0/P1=0.

Fixed:
- Supabase Free/Tokyo; Asia/Tokyo only.
- max 2 active adults.
- Edge auth exact from EDGE_FUNCTION_AUTH_MATRIX.md + supabase/config.toml.
- private schema not exposed; service-role public.server_tx_* only.
- LINE actor from signed source.userId mapping only.
- APP_LINE_MONTHLY_HARD_CAP=200.
- atomic quota reservation before counted call.
- LINE retry safety expiry 23h; no retry after expiry.
- ambiguous expired => delivery_unknown.
- Google OAuth scopes fixed.
- Calendar accessRole writerWithoutPrivateAccess/writer/owner only.
- Calendar timezone Asia/Tokyo.
- recurring identity from originalStartTime.
- no local RFC5545 parser.
- busy classification normalized parent/member.
- Google updates GET + events.patch + If-Match + sendUpdates=none.
- fresh evening routine setup mandatory.
- weekends/holidays only 09:00 and 20:00 LINE routines.
- Sunday 09:00 bundles next-week; no Sunday 12:00.
- Japan holiday cache from Cabinet Office + fixture.
- R2 Standard.
- never show sender raw AI input to recipient.

If normative docs conflict, create IMPLEMENTATION_BLOCKER.md and stop before migration.
No force push.

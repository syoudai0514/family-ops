# 0005. New WP7 error codes live in `_shared/googleCalendar.ts`, not
`_shared/errors.ts`

## Status

Accepted (collision-safe workaround — see "Consequences" for the intended
follow-up)

## Context

This work package's collision-avoidance constraints (parallel WP6 agent in
the same shared checkout) forbid editing any existing file under
`supabase/functions/_shared/`, including `errors.ts`. But
`docs/design/v6/07_GOOGLE_CALENDAR.md` requires several outcomes that don't
map onto any of `errors.ts`'s existing `HTTP_STATUS_BY_CODE` entries:

- `GOOGLE_OAUTH_STATE_INVALID` (expired/replayed/unknown OAuth state, #2A)
- `CALENDAR_TIMEZONE_UNSUPPORTED` (#5A, target calendar timezone ≠
  Asia/Tokyo)
- `CALENDAR_NO_ELIGIBLE_CALENDAR` (#5A, no writer(WithoutPrivateAccess)/owner
  calendar found)
- `CALENDAR_ETAG_CONFLICT` (#12, 412 with fields not already at the desired
  value)
- `CALENDAR_REAUTH_REQUIRED` (#2, `invalid_grant` from Google's token
  endpoint)
- `CALENDAR_UNAVAILABLE` (transient provider timeout on create/update)
- `CALENDAR_EVENT_NOT_FOUND` (target event vanished before an update PATCH)
- `GOOGLE_SYNC_LEASE_LOST` (worker-internal; a sync job lease was reclaimed
  by another worker before this one finished)

`errors.ts`'s `statusForCode()` falls back to 500 for any code missing from
its map, and `_shared/rpc.ts`'s `callServerTx` downgrades any code missing
from `isKnownErrorCode()` to a generic `INTERNAL_ERROR`/500 — so simply
`raise exception 'CALENDAR_ETAG_CONFLICT'` from a `server_tx_*` RPC and
calling it through the existing helpers would silently turn a real 409 into
an opaque 500, and lose the code entirely.

## Decision

`supabase/functions/_shared/googleCalendar.ts` (a new file) defines its own
`GOOGLE_ERROR_STATUS` map plus `googleErrorResponse` /
`callGoogleServerTx` / `toGoogleErrorResponse`, which every WP7 Edge
Function uses in place of `errors.ts`'s `errorResponse` /
`_shared/rpc.ts`'s `callServerTx` / `_shared/handler.ts`'s
`withUserMutationHandler`. These new helpers still defer to `errors.ts`'s
existing `describeCode`/`isKnownErrorCode`/`statusForCode` for every
already-known code (`INVALID_INPUT`, `NOT_HOUSEHOLD_MEMBER`,
`CROSS_HOUSEHOLD_RESOURCE`, `IDEMPOTENCY_CONFLICT`, ...) — only the WP7-new
codes above get their status from the new local map instead.

Two Edge Functions (`create-calendar-event`, `update-calendar-event`) can
raise these new codes directly (not only via an RPC exception), so they use
`toGoogleErrorResponse` as their top-level catch instead of
`withUserMutationHandler`, which would otherwise route any thrown
`FamilyOpsError` through `errors.ts`'s `errorResponse` and its 500 fallback
regardless of the `httpStatus` the error was constructed with.

## Consequences

- The error code catalogue is temporarily split across two files. A human
  should fold `GOOGLE_ERROR_STATUS`'s entries into `errors.ts`'s
  `HTTP_STATUS_BY_CODE`/`KNOWN_CODES`/`describeCode` in a follow-up change
  that is not constrained by this work package's collision-avoidance rules,
  then simplify the WP7 Edge Functions back onto the standard
  `withUserMutationHandler`/`callServerTx` helpers.
- Until that follow-up lands, any *other* work package's Edge Function that
  calls one of the WP7 `server_tx_*` RPCs directly (bypassing
  `callGoogleServerTx`) would see these codes downgraded to a generic 500,
  same as before this ADR. None of WP7's own Edge Functions have this
  problem since they all route through `callGoogleServerTx`.

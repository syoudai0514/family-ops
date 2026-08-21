# EDGE_FUNCTION_AUTH_MATRIX — v6 normative

## Classes

| class | verify_jwt | in-handler authentication |
|---|---:|---|
| user mutation | true | JWT sub -> canonical membership |
| external provider | false | signature/watch/state validation |
| cron worker | false | X-Family-Ops-Worker-Token constant-time compare |

## User-facing — verify_jwt=true
- create-household
- create-household-invite
- join-household
- create-task
- edit-task
- cancel-task
- complete-task
- set-subtask-completion
- reassign-task-once
- create-task-definition
- edit-task-definition
- deactivate-task-definition
- change-recurrence
- deactivate-recurrence
- complete-onboarding-step
- replace-recurrence-schedule
- configure-evening-routines
- send-request
- accept-request
- decline-request
- cancel-request
- add-shopping-item
- assign-shopping-item
- order-shopping-item
- purchase-shopping-item
- arrive-shopping-item
- cancel-shopping-item
- create-handover
- mark-handover-read
- mark-notification-read
- update-notification-preferences
- update-routine-schedule
- get-routine-session
- complete-routine-session
- routine-session-item-action
- google-calendar-oauth-start
- create-calendar-event
- update-calendar-event
- classify-calendar-busy-members
- ensure-calendar-fresh
- get-week-schedule
- create-line-link-token
- unlink-line-account

No/malformed JWT => platform 401 before business handler.

## External provider — verify_jwt=false

### line-webhook-receiver
Verify raw-body LINE signature before parse.

### google-calendar-webhook
Verify channel id/resource id/channel token against active/retiring DB watch.

### google-calendar-oauth-callback
Verify single-use OAuth state; callback needs no browser JWT.

## Worker — verify_jwt=false
- process-line-inbox
- process-pending-actions
- send-notifications
- dispatch-routine-automation
- enqueue-periodic-google-sync
- process-google-sync
- renew-google-watch
- materialize-recurring
- cleanup-expired-private-data
- sync-jp-holidays

Handler order:
1. read X-Family-Ops-Worker-Token
2. constant-time compare
3. wrong/missing => 401
4. only then create service-role client / touch DB

## CI
- parse config.toml
- every deployed function appears in matrix
- exact true/false match
- no unknown function
- provider/worker auth works without Supabase JWT
- user mutation without JWT rejected by gateway
- worker wrong token rejected before DB access

// Single source of truth for Edge Function names, so a rename on the backend
// is a one-line fix here instead of a grep-and-replace across every screen.
export const EDGE_FUNCTIONS = {
  createHousehold: 'create-household',
  createHouseholdInvite: 'create-household-invite',
  joinHousehold: 'join-household',
  configureEveningRoutines: 'configure-evening-routines',
  // Confirmed against supabase/functions/configure-dropoff-pickup/index.ts —
  // was built against a "server-configure-dropoff-pickup" placeholder name
  // before the backend landed; renamed to match once it shipped.
  configureDropoffPickup: 'configure-dropoff-pickup',
  createTask: 'create-task',
  editTask: 'edit-task',
  cancelTask: 'cancel-task',
  completeTask: 'complete-task',
  setSubtaskCompletion: 'set-subtask-completion',
  createTaskDefinition: 'create-task-definition',
  editTaskDefinition: 'edit-task-definition',
  deactivateTaskDefinition: 'deactivate-task-definition',
  sendRequest: 'send-request',
  acceptRequest: 'accept-request',
  declineRequest: 'decline-request',
  cancelRequest: 'cancel-request',
  proposeAiDraft: 'propose-ai-draft',
  addShoppingItem: 'add-shopping-item',
  assignShoppingItem: 'assign-shopping-item',
  orderShoppingItem: 'order-shopping-item',
  purchaseShoppingItem: 'purchase-shopping-item',
  arriveShoppingItem: 'arrive-shopping-item',
  cancelShoppingItem: 'cancel-shopping-item',
  createHandover: 'create-handover',
  markHandoverRead: 'mark-handover-read',
  markNotificationRead: 'mark-notification-read',
  updateNotificationPreferences: 'update-notification-preferences',
  createLineLinkToken: 'create-line-link-token',
  updateRoutineSchedule: 'update-routine-schedule',
  changeRecurrence: 'change-recurrence',
  deactivateRecurrence: 'deactivate-recurrence',
  reassignTaskOnce: 'reassign-task-once',
  confirmRequestDraft: 'confirm-request-draft',
  createAssignmentChangeRequest: 'create-assignment-change-request',
  acceptAssignmentChangeRequest: 'accept-assignment-change-request',
  // WP8 (routine LINE automation) — /checkin/:sessionId (features/checkin).
  getRoutineSession: 'get-routine-session',
  completeRoutineSession: 'complete-routine-session',
  routineSessionItemAction: 'routine-session-item-action',
  // Sol re-review #3 fix (P1-1/P1-2, docs/adr/0011) — Today Priority 1/2.
  listPendingActions: 'list-pending-actions',
  confirmPendingAction: 'confirm-pending-action',
  cancelPendingAction: 'cancel-pending-action',
  getTodaySchedule: 'get-today-schedule',
} as const;

export type EdgeFunctionName = (typeof EDGE_FUNCTIONS)[keyof typeof EDGE_FUNCTIONS];

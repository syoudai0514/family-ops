// Read-model row shapes, mirroring the tables listed in the WP2 contract.
// These are intentionally hand-written (not generated) — keep in sync with
// supabase/migrations if columns change; do not add columns speculatively.

export type MemberRole = 'primary' | 'partner' | string;

export interface Household {
  id: string;
  name: string;
  timezone: string;
  /** Set by configure-evening-routines on successful submission; null = wizard step not done. */
  evening_routine_setup_completed_at: string | null;
  /** Set by the dropoff/pickup setup Edge Function on successful submission; null = wizard step not done. */
  dropoff_pickup_setup_completed_at: string | null;
  morning_preparation_setup_completed_at: string | null;
  connections_setup_completed_at: string | null;
  notification_preferences_setup_completed_at: string | null;
  onboarding_preview_completed_at: string | null;
}

export interface HouseholdMember {
  household_id: string;
  user_id: string;
  member_role: MemberRole;
  joined_at: string;
}

export interface Profile {
  user_id: string;
  display_name: string;
}

export type RoutinePhase = 'morning' | 'evening' | 'anytime';
export type CompletionMode = 'whole' | 'subtasks';

export interface TaskDefinition {
  id: string;
  household_id: string;
  code: string;
  title: string;
  category: string;
  routine_phase: RoutinePhase;
  completion_mode: CompletionMode;
  is_active: boolean;
  sort_order: number;
}

export interface TaskSubtaskDefinition {
  id: string;
  household_id: string;
  task_definition_id: string;
  title: string;
  required: boolean;
  sort_order: number;
}

export type TaskInstanceStatus = 'todo' | 'in_progress' | 'completed' | 'skipped' | 'cancelled';

export interface TaskInstance {
  id: string;
  household_id: string;
  task_definition_id: string | null;
  recurrence_rule_id: string | null;
  origin: string;
  title: string;
  category: string;
  routine_phase: RoutinePhase | null;
  scheduled_date: string;
  due_at: string | null;
  planned_assignee_id: string | null;
  completion_mode: CompletionMode;
  status: TaskInstanceStatus;
  actual_completed_by_id: string | null;
  completed_at: string | null;
}

export interface TaskSubtaskInstance {
  id: string;
  household_id: string;
  task_instance_id: string;
  title: string;
  required: boolean;
  sort_order: number;
  is_completed: boolean;
  completed_by: string | null;
  completed_at: string | null;
}

export type RequestStatus = 'pending' | 'accepted' | 'declined' | 'completed' | 'cancelled';

export interface RequestRow {
  id: string;
  household_id: string;
  requester_id: string;
  recipient_id: string;
  shared_title: string;
  shared_message: string | null;
  due_at: string | null;
  status: RequestStatus;
  linked_task_instance_id: string | null;
  accepted_at: string | null;
  declined_at: string | null;
  completed_at: string | null;
  cancelled_at: string | null;
  assignment_task_instance_id?: string | null;
  assignment_scope?: 'once' | 'this_week' | null;
}

export type HandoverPeriod = 'morning' | 'day' | 'evening' | 'other';

export interface Handover {
  id: string;
  household_id: string;
  author_id: string;
  shared_text: string;
  period: HandoverPeriod;
  categories: string[];
  occurred_on: string;
  created_at: string;
}

export interface HandoverRead {
  household_id: string;
  handover_id: string;
  user_id: string;
  read_at: string;
}

export type PurchaseMethod = 'store' | 'online' | 'either' | 'undecided';
export type ShoppingItemStatus =
  'wanted' | 'assigned' | 'ordered' | 'purchased' | 'arrived' | 'cancelled';

export interface ShoppingItem {
  id: string;
  household_id: string;
  title: string;
  purchase_method: PurchaseMethod;
  status: ShoppingItemStatus;
  assignee_id: string | null;
  url: string | null;
  due_at: string | null;
  ordered_at: string | null;
  purchased_at: string | null;
  arrived_at: string | null;
}

export interface UserNotification {
  id: string;
  household_id: string;
  recipient_user_id: string;
  type: string;
  title: string;
  body: string | null;
  payload: unknown;
  dedup_key: string | null;
  read_at: string | null;
  created_at: string;
}

export interface NotificationPreferences {
  household_id: string;
  user_id: string;
  request_line: boolean;
  handover_line: boolean;
  calendar_line: boolean;
  conflict_line: boolean;
  routine_completion_line: boolean;
  shopping_minor_line: boolean;
  weekly_digest_line: boolean;
  daily_assignment_line: boolean;
  routine_checklist_line: boolean;
  routine_checkin_prompt_line: boolean;
  in_app: boolean;
  updated_at: string;
}

export type RoutineScheduleKind =
  | 'daily_assignment'
  | 'dropoff_checklist'
  | 'dropoff_checkin'
  | 'pickup_checklist'
  | 'pickup_checkin'
  | 'nonpickup_evening_checklist'
  | 'nonpickup_evening_checkin'
  | 'nonworkday_morning_digest'
  | 'nonworkday_checkin';

export const ROUTINE_SCHEDULE_KINDS: RoutineScheduleKind[] = [
  'daily_assignment',
  'dropoff_checklist',
  'dropoff_checkin',
  'pickup_checklist',
  'pickup_checkin',
  'nonpickup_evening_checklist',
  'nonpickup_evening_checkin',
  'nonworkday_morning_digest',
  'nonworkday_checkin',
];

export interface HouseholdRoutineSchedule {
  id: string;
  household_id: string;
  schedule_kind: RoutineScheduleKind;
  local_time: string;
  enabled: boolean;
  schedule_version: number;
}

export const EVENING_ROUTINE_TASK_CODES = [
  'dinner',
  'bath',
  'laundry',
  'dishes',
  'cleaning',
  'smile_zemi',
  'media_30min',
] as const;

export type EveningRoutineTaskCode = (typeof EVENING_ROUTINE_TASK_CODES)[number];

export type AssigneeStrategy = 'pickup_assignee' | 'nonpickup_adult' | 'fixed';

// WP4 — append-only audit trail behind the "planned vs actual" history view.
// event_type values mirror the literals inserted by the mutation RPCs (see
// supabase/migrations/2026081900{0016,0019,0025,0081,0083}_*.sql).
export type TaskEventType =
  | 'created'
  | 'edited'
  | 'cancelled'
  | 'completed'
  | 'subtask_completed'
  | 'reassigned_once'
  | 'skipped';

export interface TaskEvent {
  id: string;
  household_id: string;
  task_instance_id: string;
  actor_id: string;
  event_type: TaskEventType;
  payload: Record<string, unknown>;
  source: string;
  idempotency_key: string | null;
  created_at: string;
}

// Sol re-review #3 fix (P1-1, docs/adr/0011) — Today Priority 2's "LINEから
// 作ったpending action" (02_UX_AND_SCREENS.md #3). Mirrors
// server_tx_list_pending_actions's jsonb shape
// (20260819000102_pending_action_review_and_today_schedule.sql). Only ever
// the current actor's own rows — never the partner's.
export type PendingActionStatus = 'draft' | 'confirmed' | 'queued' | 'executing';
export type PendingActionType =
  | 'shopping_item_add'
  | 'task_create_once'
  | 'assignment_change_request'
  | 'needs_pwa_review';

export interface PendingAction {
  id: string;
  action_type: PendingActionType;
  normalized_payload: Record<string, unknown>;
  status: PendingActionStatus;
  source: 'line' | 'pwa';
  expires_at: string;
  created_at: string;
}

// Sol re-review #3 fix (P1-2, docs/adr/0011) — Today Priority 1's "今/次の予定"
// (02_UX_AND_SCREENS.md #3). Mirrors server_tx_get_today_schedule's jsonb
// shape. occurrences/assignments are already filtered/conflict-annotated
// server-side — the frontend renders this as-is, no calendar-domain
// computation of its own.
export interface TodayCalendarOccurrence {
  occurrence_key: string;
  title: string | null;
  starts_at: string;
  ends_at: string | null;
  busy_user_ids: string[];
}

export interface TodayScheduleAssignment {
  task_instance_id: string;
  title: string;
  category: string;
  due_at: string;
  planned_assignee_id: string;
  has_conflict: boolean;
}

export interface TodaySchedule {
  household_id: string;
  local_date: string;
  calendar_connected: boolean;
  calendar_stale: boolean;
  occurrences: TodayCalendarOccurrence[];
  assignments: TodayScheduleAssignment[];
}

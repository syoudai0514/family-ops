// Read-model row shapes, mirroring the tables listed in the WP2 contract.
// These are intentionally hand-written (not generated) — keep in sync with
// supabase/migrations if columns change; do not add columns speculatively.

export type MemberRole = 'adult' | string;
export type FamilyRole = 'papa' | 'mama' | null;

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
  family_role?: FamilyRole;
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
  task_kind?: TaskKind;
  include_in_routine_line?: boolean;
}

export type TaskKind = 'transport' | 'morning_preparation' | 'morning_chore' | 'evening_chore' | 'special' | 'generic_once';

export interface TaskSubtaskDefinition {
  id: string;
  household_id: string;
  task_definition_id: string;
  title: string;
  required: boolean;
  sort_order: number;
}

export type TaskInstanceStatus = 'todo' | 'in_progress' | 'completed' | 'skipped' | 'cancelled';
export type TaskOutcomeReason =
  | 'could_not_do'
  | 'not_needed_this_occurrence'
  | 'expired_occurrence'
  | 'rescheduled'
  | 'unknown'
  | null;
export type TaskAttentionState = 'active' | 'waiting';
export type TaskAssignmentMode = 'person' | 'unassigned' | 'anyone';

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
  calendar_ends_at?: string | null;
  calendar_visibility?: 'transport' | 'special' | 'hidden' | null;
  task_kind?: TaskKind;
  planned_assignee_id: string | null;
  assignment_mode?: TaskAssignmentMode | null;
  completion_mode: CompletionMode;
  status: TaskInstanceStatus;
  actual_completed_by_id: string | null;
  completed_at: string | null;
  outcome_reason?: TaskOutcomeReason;
  rescheduled_to?: string | null;
  attention_state?: TaskAttentionState;
  waiting_note?: string | null;
  next_check_at?: string | null;
  revision?: number;
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
  revision?: number;
  linked_task_revision?: number | null;
  linked_task_title?: string | null;
  linked_task_due_at?: string | null;
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
  info_kind?: 'share' | 'handover';
  valid_from?: string;
  valid_until?: string | null;
  ack_policy?: 'none' | 'required';
  status?: 'active' | 'superseded' | 'expired';
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
  assignment_mode?: 'person' | 'unassigned' | 'anyone' | null;
  assignee_actor_ref_id?: string | null;
  active_claimant_actor_ref_id?: string | null;
  claimed_at?: string | null;
}

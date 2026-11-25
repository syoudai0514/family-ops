-- #198 storage foundation only. No scheduler or task mutation is enabled here.
-- A separately reviewed command must capture the pre-close state while holding
-- the task lock, so correction/undo can restore the exact earlier information.
alter table public.task_instances drop constraint task_instances_outcome_reason_check;
alter table public.task_instances add constraint task_instances_outcome_reason_check
  check (outcome_reason is null or outcome_reason in (
    'could_not_do','not_needed_this_occurrence','expired_occurrence','rescheduled','unknown','unrecorded'
  ));
alter table public.task_instances add constraint task_instances_unrecorded_status_check
  check (outcome_reason is distinct from 'unrecorded' or status='skipped');

create table private.unrecorded_routine_archives (
  household_id uuid not null,
  task_id uuid not null,
  before_revision bigint not null check (before_revision>=1),
  closed_revision bigint not null check (closed_revision=before_revision+1),
  before_state jsonb not null check (jsonb_typeof(before_state)='object'
    and before_state ? 'status' and before_state ? 'attention_state'
    and before_state ? 'active_claimant_actor_ref_id' and before_state ? 'claimed_at'
    and before_state ? 'waiting_note' and before_state ? 'next_check_at'
    and before_state ? 'outcome_reason' and before_state ? 'rescheduled_to'
    and before_state ? 'actual_completed_by_id' and before_state ? 'completed_at'),
  archived_at timestamptz not null default now(),
  primary key (household_id,task_id,closed_revision),
  foreign key (household_id,task_id) references public.task_instances(household_id,id) on delete cascade
);
alter table private.unrecorded_routine_archives enable row level security;
revoke all on private.unrecorded_routine_archives from public,anon,authenticated,service_role;

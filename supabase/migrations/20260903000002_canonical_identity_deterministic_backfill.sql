-- Canonical detailed-design implementation, Batch 1A / WP-DD2 deterministic backfill.
-- Backfill is idempotent and deliberately makes no guessed performer, anyone
-- assignment, skipped-outcome, Family Event, or simulated-identity claim.

create or replace function private.backfill_canonical_foundation_v1()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_inserted int := 0;
  v_task_assignment_updated int := 0;
  v_task_event_updated int := 0;
  v_request_updated int := 0;
  v_request_attempt_inserted int := 0;
  v_handover_updated int := 0;
  v_shopping_updated int := 0;
  v_participant_inserted int := 0;
  v_rows int := 0;
begin
  -- Exactly one canonical real-user ActorRef per current household member.
  insert into public.domain_actor_refs (household_id, actor_kind, real_user_id)
  select m.household_id, 'real_user', m.user_id
  from public.household_members m
  on conflict (household_id, real_user_id) where actor_kind = 'real_user' do nothing;
  get diagnostics v_actor_inserted = row_count;

  -- Legacy non-null assignee maps losslessly to person + matching real ActorRef.
  update public.task_instances t
  set planned_assignee_actor_ref_id = a.id,
      assignment_mode = 'person',
      assignment_source = 'legacy_snapshot'
  from public.domain_actor_refs a
  where t.test_context_id is null
    and t.planned_assignee_id is not null
    and a.household_id = t.household_id
    and a.actor_kind = 'real_user'
    and a.real_user_id = t.planned_assignee_id
    and (t.planned_assignee_actor_ref_id is distinct from a.id
         or t.assignment_mode is distinct from 'person'
         or t.assignment_source is distinct from 'legacy_snapshot');
  get diagnostics v_rows = row_count;
  v_task_assignment_updated := v_task_assignment_updated + v_rows;

  -- Legacy null assignee is represented as unassigned, never guessed as anyone.
  -- Do not overwrite a future explicit anyone/person canonical value if this
  -- helper is rerun during the compatibility window.
  update public.task_instances t
  set assignment_mode = 'unassigned',
      assignment_source = 'legacy_snapshot',
      planned_assignee_actor_ref_id = null
  where t.test_context_id is null
    and t.planned_assignee_id is null
    and (t.assignment_mode is null or t.assignment_mode = 'unassigned')
    and (t.assignment_mode is distinct from 'unassigned'
         or t.assignment_source is distinct from 'legacy_snapshot'
         or t.planned_assignee_actor_ref_id is not null);
  get diagnostics v_rows = row_count;
  v_task_assignment_updated := v_task_assignment_updated + v_rows;

  -- Current Task-event actor is known when legacy actor_id is present.
  update public.task_events e
  set actor_ref_id = a.id
  from public.domain_actor_refs a
  where e.test_context_id is null
    and e.actor_id is not null
    and a.household_id = e.household_id
    and a.actor_kind = 'real_user'
    and a.real_user_id = e.actor_id
    and e.actor_ref_id is distinct from a.id;
  get diagnostics v_task_event_updated = row_count;

  -- Request actor identity and kind are deterministic from current columns.
  update public.requests r
  set requester_actor_ref_id = requester.id,
      recipient_actor_ref_id = recipient.id,
      request_kind = case
        when r.assignment_task_instance_id is not null or r.assignment_scope is not null
          then 'assignment_change'
        else 'light'
      end
  from public.domain_actor_refs requester,
       public.domain_actor_refs recipient
  where r.test_context_id is null
    and requester.household_id = r.household_id
    and requester.actor_kind = 'real_user'
    and requester.real_user_id = r.requester_id
    and recipient.household_id = r.household_id
    and recipient.actor_kind = 'real_user'
    and recipient.real_user_id = r.recipient_id
    and (r.requester_actor_ref_id is distinct from requester.id
         or r.recipient_actor_ref_id is distinct from recipient.id
         or r.request_kind is null);
  get diagnostics v_request_updated = row_count;

  -- One historical initial Attempt captures the agreement fact. Historical
  -- Request completed means the initial agreement was accepted; execution
  -- completion remains legacy history and is not made a new Attempt state.
  insert into public.request_attempts (
    household_id, request_id, attempt_kind, state, terms_revision, terms,
    created_by_actor_ref_id, accepted_at, declined_at, cancelled_at,
    legacy_backfill, created_at, updated_at
  )
  select
    r.household_id,
    r.id,
    'initial',
    case r.status
      when 'pending' then 'pending'
      when 'accepted' then 'accepted'
      when 'completed' then 'accepted'
      when 'declined' then 'declined'
      when 'cancelled' then 'cancelled'
    end,
    1,
    jsonb_build_object('legacy_status', r.status),
    r.requester_actor_ref_id,
    case when r.status in ('accepted', 'completed') then r.accepted_at else null end,
    case when r.status = 'declined' then r.declined_at else null end,
    case when r.status = 'cancelled' then r.cancelled_at else null end,
    true,
    r.created_at,
    r.updated_at
  from public.requests r
  where r.test_context_id is null
    and r.requester_actor_ref_id is not null
    and not exists (
      select 1 from public.request_attempts a
      where a.request_id = r.id and a.legacy_backfill
    );
  get diagnostics v_request_attempt_inserted = row_count;

  update public.handovers h
  set author_actor_ref_id = a.id
  from public.domain_actor_refs a
  where h.test_context_id is null
    and a.household_id = h.household_id
    and a.actor_kind = 'real_user'
    and a.real_user_id = h.author_id
    and h.author_actor_ref_id is distinct from a.id;
  get diagnostics v_handover_updated = row_count;

  update public.shopping_items s
  set assignee_actor_ref_id = a.id,
      assignment_mode = 'person'
  from public.domain_actor_refs a
  where s.test_context_id is null
    and s.assignee_id is not null
    and a.household_id = s.household_id
    and a.actor_kind = 'real_user'
    and a.real_user_id = s.assignee_id
    and (s.assignee_actor_ref_id is distinct from a.id
         or s.assignment_mode is distinct from 'person');
  get diagnostics v_rows = row_count;
  v_shopping_updated := v_shopping_updated + v_rows;

  update public.shopping_items s
  set assignee_actor_ref_id = null,
      assignment_mode = 'unassigned'
  where s.test_context_id is null
    and s.assignee_id is null
    and (s.assignment_mode is null or s.assignment_mode = 'unassigned')
    and (s.assignee_actor_ref_id is not null
         or s.assignment_mode is distinct from 'unassigned');
  get diagnostics v_rows = row_count;
  v_shopping_updated := v_shopping_updated + v_rows;

  -- Legacy actual_completed_by_id is a known performer. Recorder identity is
  -- not separately knowable from legacy rows, so recorded_by stays null.
  insert into public.task_actual_participants (
    household_id, task_instance_id, actor_ref_id, participation_kind,
    recorded_by_actor_ref_id, recorded_at, compatibility_primary, source,
    test_context_id
  )
  select
    t.household_id,
    t.id,
    a.id,
    'performed',
    null,
    coalesce(t.completed_at, t.updated_at, t.created_at),
    true,
    'legacy_backfill',
    null
  from public.task_instances t
  join public.domain_actor_refs a
    on a.household_id = t.household_id
   and a.actor_kind = 'real_user'
   and a.real_user_id = t.actual_completed_by_id
  where t.test_context_id is null
    and t.actual_completed_by_id is not null
    and not exists (
      select 1 from public.task_actual_participants p
      where p.task_instance_id = t.id
        and p.actor_ref_id = a.id
        and p.removed_at is null
    );
  get diagnostics v_participant_inserted = row_count;

  return jsonb_build_object(
    'actor_refs_inserted', v_actor_inserted,
    'task_assignment_rows_updated', v_task_assignment_updated,
    'task_event_rows_updated', v_task_event_updated,
    'request_rows_updated', v_request_updated,
    'request_attempts_inserted', v_request_attempt_inserted,
    'handover_rows_updated', v_handover_updated,
    'shopping_rows_updated', v_shopping_updated,
    'participants_inserted', v_participant_inserted
  );
end;
$$;

revoke all on function private.backfill_canonical_foundation_v1() from public, anon, authenticated;
grant execute on function private.backfill_canonical_foundation_v1() to service_role;

-- Backfill rows present at migration time. Old runtime may continue writing
-- during R0/R1, so this helper is intentionally retained and rerunnable before
-- any aggregate P1 cutover.
select private.backfill_canonical_foundation_v1();

create or replace function private.canonical_foundation_reconciliation_v1()
returns table(issue_type text, issue_count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select 'household_member_without_real_actor_ref'::text, count(*)
  from public.household_members m
  where not exists (
    select 1 from public.domain_actor_refs a
    where a.household_id = m.household_id
      and a.actor_kind = 'real_user'
      and a.real_user_id = m.user_id
  )

  union all
  select 'task_planned_actor_mismatch'::text, count(*)
  from public.task_instances t
  left join public.domain_actor_refs a
    on a.id = t.planned_assignee_actor_ref_id and a.household_id = t.household_id
  where t.test_context_id is null and t.planned_assignee_id is not null
    and (a.id is null or a.real_user_id is distinct from t.planned_assignee_id)

  union all
  select 'task_event_actor_mismatch'::text, count(*)
  from public.task_events e
  left join public.domain_actor_refs a
    on a.id = e.actor_ref_id and a.household_id = e.household_id
  where e.test_context_id is null and e.actor_id is not null
    and (a.id is null or a.real_user_id is distinct from e.actor_id)

  union all
  select 'request_actor_mismatch'::text, count(*)
  from public.requests r
  left join public.domain_actor_refs rq
    on rq.id = r.requester_actor_ref_id and rq.household_id = r.household_id
  left join public.domain_actor_refs rc
    on rc.id = r.recipient_actor_ref_id and rc.household_id = r.household_id
  where r.test_context_id is null
    and (rq.real_user_id is distinct from r.requester_id
         or rc.real_user_id is distinct from r.recipient_id)

  union all
  select 'legacy_request_without_backfill_attempt'::text, count(*)
  from public.requests r
  where r.test_context_id is null
    and not exists (
      select 1 from public.request_attempts a
      where a.request_id = r.id and a.legacy_backfill
    )

  union all
  select 'legacy_completed_actor_without_participant'::text, count(*)
  from public.task_instances t
  where t.test_context_id is null and t.actual_completed_by_id is not null
    and not exists (
      select 1
      from public.task_actual_participants p
      join public.domain_actor_refs a on a.id = p.actor_ref_id
      where p.task_instance_id = t.id
        and p.removed_at is null
        and a.real_user_id = t.actual_completed_by_id
    )

  union all
  select 'production_row_with_simulated_actor_ref'::text, count(*)
  from (
    select t.household_id, t.planned_assignee_actor_ref_id as actor_ref_id, t.test_context_id
      from public.task_instances t
    union all
    select t.household_id, t.active_claimant_actor_ref_id, t.test_context_id
      from public.task_instances t
    union all
    select r.household_id, r.requester_actor_ref_id, r.test_context_id from public.requests r
    union all
    select r.household_id, r.recipient_actor_ref_id, r.test_context_id from public.requests r
    union all
    select s.household_id, s.assignee_actor_ref_id, s.test_context_id from public.shopping_items s
    union all
    select s.household_id, s.active_claimant_actor_ref_id, s.test_context_id from public.shopping_items s
  ) x
  join public.domain_actor_refs a
    on a.id = x.actor_ref_id and a.household_id = x.household_id
  where x.test_context_id is null and a.actor_kind = 'simulated_member';
$$;

revoke all on function private.canonical_foundation_reconciliation_v1() from public, anon, authenticated;
grant execute on function private.canonical_foundation_reconciliation_v1() to service_role;

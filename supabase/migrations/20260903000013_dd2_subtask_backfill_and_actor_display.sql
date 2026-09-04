-- WP-DD2 deterministic subtask ActorRef convergence + DD3A semantic actor label.

alter function private.backfill_canonical_foundation_v1()
  rename to backfill_canonical_foundation_v1_pre_subtask_actor;

create or replace function private.backfill_canonical_foundation_v1()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base jsonb;
  v_subtask_actor_updated int := 0;
begin
  v_base := private.backfill_canonical_foundation_v1_pre_subtask_actor();

  update public.task_subtask_instances s
  set completed_by_actor_ref_id = a.id,
      recorded_by_actor_ref_id = coalesce(s.recorded_by_actor_ref_id, a.id)
  from public.domain_actor_refs a
  where s.test_context_id is null
    and s.completed_by is not null
    and a.household_id = s.household_id
    and a.actor_kind = 'real_user'
    and a.real_user_id = s.completed_by
    and (s.completed_by_actor_ref_id is distinct from a.id
         or s.recorded_by_actor_ref_id is null);
  get diagnostics v_subtask_actor_updated = row_count;

  return v_base || jsonb_build_object(
    'subtask_actor_refs_updated', v_subtask_actor_updated
  );
end;
$$;
revoke all on function private.backfill_canonical_foundation_v1()
  from public, anon, authenticated;
grant execute on function private.backfill_canonical_foundation_v1() to service_role;

alter function private.canonical_foundation_reconciliation_v1()
  rename to canonical_foundation_reconciliation_v1_pre_subtask_actor;

create or replace function private.canonical_foundation_reconciliation_v1()
returns table(issue_type text, issue_count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select * from private.canonical_foundation_reconciliation_v1_pre_subtask_actor()

  union all
  select 'production_completed_subtask_missing_actor_ref'::text, count(*)
  from public.task_subtask_instances s
  where s.test_context_id is null
    and s.is_completed
    and s.completed_by is not null
    and s.completed_by_actor_ref_id is null

  union all
  select 'test_subtask_with_legacy_real_user_actor'::text, count(*)
  from public.task_subtask_instances s
  where s.test_context_id is not null and s.completed_by is not null;
$$;
revoke all on function private.canonical_foundation_reconciliation_v1()
  from public, anon, authenticated;
grant execute on function private.canonical_foundation_reconciliation_v1() to service_role;

-- Canonical readers later own full presentation. This helper provides the
-- identity-safe minimum needed by test/audit surfaces now: a simulated actor is
-- visibly test-only and never rendered as the real operator who authorized it.
create or replace function private.fn_actor_display_label_v1(
  p_household_id uuid,
  p_actor_ref_id uuid
) returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_kind text;
  v_role text;
  v_real_user_id uuid;
begin
  select actor_kind, simulated_role, real_user_id
    into v_kind, v_role, v_real_user_id
  from public.domain_actor_refs
  where household_id = p_household_id and id = p_actor_ref_id;
  if not found then raise exception 'ACTOR_REF_NOT_IN_HOUSEHOLD'; end if;

  if v_kind = 'simulated_member' then
    return case v_role
      when 'mama' then '🧪 ママ'
      when 'papa' then '🧪 パパ'
      else '🧪 テストメンバー'
    end;
  elsif v_kind = 'system' then
    return 'システム';
  end if;

  -- Real-user display-name enrichment belongs to the canonical read package;
  -- this fallback remains identity-correct without coupling command foundation
  -- to profile presentation schema.
  return 'real:' || v_real_user_id::text;
end;
$$;
revoke all on function private.fn_actor_display_label_v1(uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.fn_actor_display_label_v1(uuid, uuid) to service_role;

-- Re-run the now-extended idempotent R0 backfill so rows created/changed by the
-- still-active legacy runtime converge before review. No semantic state is enabled.
select private.backfill_canonical_foundation_v1();

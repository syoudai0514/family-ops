-- WP-DD3A child-scope hardening + WP-DD3 candidate-resolution boundary.

create or replace function private.fn_enforce_dd1b_child_test_context_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_parent_test_context_id uuid;
  v_parent_household_id uuid;
begin
  if tg_table_name = 'task_subtask_instances' then
    select household_id, test_context_id into v_parent_household_id, v_parent_test_context_id
    from public.task_instances
    where household_id = new.household_id and id = new.task_instance_id;
  elsif tg_table_name = 'shopping_actual_participants' then
    select household_id, test_context_id into v_parent_household_id, v_parent_test_context_id
    from public.shopping_items
    where household_id = new.household_id and id = new.shopping_item_id;
  elsif tg_table_name in ('family_event_field_authorities', 'family_event_external_links') then
    select household_id, test_context_id into v_parent_household_id, v_parent_test_context_id
    from public.family_events
    where household_id = new.household_id and id = new.family_event_id;
  elsif tg_table_name = 'document_extractions' then
    select household_id, test_context_id into v_parent_household_id, v_parent_test_context_id
    from private.source_documents
    where household_id = new.household_id and id = new.source_document_id;
  elsif tg_table_name = 'document_facts' then
    select household_id, test_context_id into v_parent_household_id, v_parent_test_context_id
    from private.document_extractions
    where household_id = new.household_id and id = new.extraction_id;
  else
    raise exception 'UNSUPPORTED_DD1B_CHILD_SCOPE_TABLE';
  end if;

  if not found then raise exception 'CANONICAL_PARENT_NOT_FOUND'; end if;
  if new.test_context_id is distinct from v_parent_test_context_id then
    raise exception 'TEST_CONTEXT_PARENT_MISMATCH';
  end if;

  if tg_table_name = 'family_event_external_links' then
    if not exists (
      select 1 from public.calendar_connections c
      where c.id = new.calendar_connection_id
        and c.household_id = new.household_id
    ) then
      raise exception 'CALENDAR_CONNECTION_HOUSEHOLD_MISMATCH';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.fn_enforce_dd1b_child_test_context_v1()
  from public, anon, authenticated;
grant execute on function private.fn_enforce_dd1b_child_test_context_v1()
  to service_role;

create trigger task_subtask_instances_test_context_guard_v2
  before insert or update of task_instance_id, test_context_id
  on public.task_subtask_instances
  for each row execute function private.fn_enforce_dd1b_child_test_context_v1();

create trigger shopping_actual_participants_test_context_guard_v1
  before insert or update of shopping_item_id, test_context_id
  on public.shopping_actual_participants
  for each row execute function private.fn_enforce_dd1b_child_test_context_v1();

create trigger family_event_field_authorities_test_context_guard_v1
  before insert or update of family_event_id, test_context_id
  on public.family_event_field_authorities
  for each row execute function private.fn_enforce_dd1b_child_test_context_v1();

create trigger family_event_external_links_test_context_guard_v1
  before insert or update of family_event_id, calendar_connection_id, test_context_id
  on public.family_event_external_links
  for each row execute function private.fn_enforce_dd1b_child_test_context_v1();

create trigger document_extractions_test_context_guard_v1
  before insert or update of source_document_id, test_context_id
  on private.document_extractions
  for each row execute function private.fn_enforce_dd1b_child_test_context_v1();

create trigger document_facts_test_context_guard_v1
  before insert or update of extraction_id, test_context_id
  on private.document_facts
  for each row execute function private.fn_enforce_dd1b_child_test_context_v1();

create trigger source_documents_actor_scope_guard_v1
  before insert or update of uploaded_by_actor_ref_id, test_context_id
  on private.source_documents
  for each row execute function private.fn_enforce_existing_actor_scope('uploaded_by_actor_ref_id');

create trigger shopping_actual_participants_actor_scope_guard_v2
  before insert or update of actor_ref_id, recorded_by_actor_ref_id, removed_by_actor_ref_id, test_context_id
  on public.shopping_actual_participants
  for each row execute function private.fn_enforce_existing_actor_scope(
    'actor_ref_id', 'recorded_by_actor_ref_id', 'removed_by_actor_ref_id'
  );

-- The Family Event provider link is an inactive foundation in this PR. Enforce
-- the stronger invariant that a test Event can never hold an enabled provider
-- writer even through a future privileged path.
alter table public.family_event_external_links
  add constraint family_event_external_links_test_writer_forbidden_v1
  check (test_context_id is null or not writer_enabled);

-- Generic candidate resolution deliberately does NOT blind-apply an accepted
-- patch. Acceptance is target-specific because it must lock/revalidate the
-- current target revision/hash and then invoke that target's canonical command
-- in the same transaction. Until those adapters land, accept fails closed.
create or replace function private.fn_command_resolve_change_candidate_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_candidate_id uuid,
  p_action text,
  p_expected_revision bigint,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_candidate public.change_candidates%rowtype;
  v_status text;
  v_revision bigint;
  v_result jsonb;
begin
  if p_action not in ('accept', 'reject', 'supersede', 'mark_stale') then
    raise exception 'CANDIDATE_RESOLUTION_ACTION_INVALID';
  end if;
  if p_source not in ('line', 'pwa') then
    raise exception 'COMMAND_SOURCE_INVALID';
  end if;

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id,
    p_operator_user_id,
    p_actor_ref_id,
    p_test_context_id,
    p_operation_id,
    'candidate.resolve.' || p_action,
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'candidate_id', p_candidate_id,
      'action', p_action,
      'expected_revision', p_expected_revision,
      'source', p_source
    ))
  );
  if v_claim->>'disposition' = 'replay' then
    return v_claim->'result_payload';
  end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_candidate
  from public.change_candidates
  where household_id = p_household_id and id = p_candidate_id
  for update;
  if not found then raise exception 'CHANGE_CANDIDATE_NOT_FOUND'; end if;
  if v_candidate.test_context_id is distinct from p_test_context_id then
    raise exception 'ACTOR_SCOPE_CONFLICT';
  end if;
  if v_candidate.revision <> p_expected_revision then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  if v_candidate.status <> 'pending' then
    raise exception 'CHANGE_CANDIDATE_NOT_PENDING';
  end if;

  if p_action = 'accept' then
    raise exception 'CANDIDATE_ACCEPT_TARGET_ADAPTER_NOT_ENABLED';
  end if;

  v_status := case p_action
    when 'reject' then 'rejected'
    when 'supersede' then 'superseded'
    when 'mark_stale' then 'stale'
  end;

  update public.change_candidates
  set status = v_status,
      resolved_at = now(),
      resolved_by_actor_ref_id = p_actor_ref_id,
      revision = revision + 1
  where household_id = p_household_id and id = p_candidate_id
  returning revision into v_revision;

  v_result := jsonb_build_object(
    'candidate_id', p_candidate_id,
    'status', v_status,
    'revision', v_revision
  );
  perform private.fn_complete_canonical_operation_v1(
    v_receipt_id, 'change_candidate', p_candidate_id, v_result
  );
  return v_result;
end;
$$;

revoke all on function private.fn_command_resolve_change_candidate_v1(
  uuid, uuid, uuid, uuid, uuid, text, bigint, uuid, text
) from public, anon, authenticated;
grant execute on function private.fn_command_resolve_change_candidate_v1(
  uuid, uuid, uuid, uuid, uuid, text, bigint, uuid, text
) to service_role;

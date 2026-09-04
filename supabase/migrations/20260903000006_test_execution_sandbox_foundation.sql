-- WP-DD3A parallel foundation: server-derived execution scope, private operation
-- receipts, and a dedicated synthetic-delivery queue. This migration does not
-- activate any PWA/LINE reader/writer or production side effect.

create table private.canonical_operation_receipts (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  operator_user_id uuid not null,
  actor_ref_id uuid not null,
  test_context_id uuid null,
  operation_id uuid not null,
  action_type text not null,
  request_hash text not null,
  result_type text null,
  result_id uuid null,
  result_payload jsonb null,
  created_at timestamptz not null default now(),
  completed_at timestamptz null,
  foreign key (household_id, operator_user_id)
    references public.household_members (household_id, user_id),
  foreign key (household_id, actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id)
);

create unique index canonical_operation_receipts_scope_operation_idx
  on private.canonical_operation_receipts (
    actor_ref_id,
    operation_id,
    coalesce(test_context_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

create index canonical_operation_receipts_household_created_idx
  on private.canonical_operation_receipts (household_id, created_at desc);

create table private.test_delivery_outbox (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  test_context_id uuid not null,
  operator_user_id uuid not null,
  semantic_actor_ref_id uuid not null,
  channel text not null default 'line' check (channel = 'line'),
  delivery_mode text not null default 'test_simulation' check (delivery_mode = 'test_simulation'),
  rendered_payload jsonb not null,
  dedup_key text not null,
  status text not null default 'queued'
    check (status in ('queued', 'sending', 'sent', 'dead')),
  attempts int not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  lease_owner text null,
  lease_token uuid null,
  lease_until timestamptz null,
  last_error text null,
  provider_message_id text null,
  sent_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (test_context_id, dedup_key),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id),
  foreign key (household_id, operator_user_id)
    references public.household_members (household_id, user_id),
  foreign key (household_id, semantic_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  check (
    status <> 'sending'
    or (lease_owner is not null and lease_token is not null and lease_until is not null)
  ),
  check (
    status <> 'sent'
    or (sent_at is not null and lease_owner is null and lease_token is null and lease_until is null)
  )
);

create index test_delivery_outbox_queue_idx
  on private.test_delivery_outbox (status, next_attempt_at, lease_until, created_at);

create trigger set_updated_at
  before update on private.test_delivery_outbox
  for each row execute function public.set_updated_at();

create or replace function private.fn_validate_execution_context_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_kind text;
  v_actor_test_context_id uuid;
  v_context_operator uuid;
  v_context_status text;
begin
  if not exists (
    select 1 from public.household_members m
    where m.household_id = p_household_id and m.user_id = p_operator_user_id
  ) then
    raise exception 'EXECUTION_OPERATOR_NOT_IN_HOUSEHOLD';
  end if;

  select a.actor_kind, a.test_context_id
    into v_actor_kind, v_actor_test_context_id
  from public.domain_actor_refs a
  where a.household_id = p_household_id and a.id = p_actor_ref_id;
  if not found then
    raise exception 'EXECUTION_ACTOR_REF_NOT_IN_HOUSEHOLD';
  end if;

  if p_test_context_id is null then
    if v_actor_kind = 'simulated_member' then
      raise exception 'SIMULATED_ACTOR_IN_PRODUCTION_EXECUTION';
    end if;
    return jsonb_build_object(
      'mode', 'production',
      'household_id', p_household_id,
      'operator_user_id', p_operator_user_id,
      'actor_ref_id', p_actor_ref_id
    );
  end if;

  select c.operator_user_id, c.status
    into v_context_operator, v_context_status
  from public.test_simulation_contexts c
  where c.household_id = p_household_id and c.id = p_test_context_id;
  if not found then
    raise exception 'TEST_CONTEXT_NOT_FOUND';
  end if;
  if v_context_status <> 'active' then
    raise exception 'TEST_CONTEXT_NOT_ACTIVE';
  end if;
  if v_context_operator is distinct from p_operator_user_id then
    raise exception 'TEST_CONTEXT_OPERATOR_MISMATCH';
  end if;
  if v_actor_kind = 'simulated_member'
     and v_actor_test_context_id is distinct from p_test_context_id then
    raise exception 'SIMULATED_ACTOR_TEST_CONTEXT_MISMATCH';
  end if;

  return jsonb_build_object(
    'mode', 'test_simulation',
    'household_id', p_household_id,
    'operator_user_id', p_operator_user_id,
    'actor_ref_id', p_actor_ref_id,
    'test_context_id', p_test_context_id
  );
end;
$$;

revoke all on function private.fn_validate_execution_context_v1(uuid, uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.fn_validate_execution_context_v1(uuid, uuid, uuid, uuid)
  to service_role;

create or replace function private.fn_enforce_execution_provenance_scope()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_context jsonb;
begin
  v_context := private.fn_validate_execution_context_v1(
    new.household_id,
    new.operator_user_id,
    new.actor_ref_id,
    new.test_context_id
  );
  return new;
end;
$$;

revoke all on function private.fn_enforce_execution_provenance_scope()
  from public, anon, authenticated;
grant execute on function private.fn_enforce_execution_provenance_scope()
  to service_role;

create trigger canonical_operation_receipts_execution_scope_guard
  before insert or update of household_id, operator_user_id, actor_ref_id, test_context_id
  on private.canonical_operation_receipts
  for each row execute function private.fn_enforce_execution_provenance_scope();

create or replace function private.fn_enforce_test_delivery_scope()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_context jsonb;
begin
  v_context := private.fn_validate_execution_context_v1(
    new.household_id,
    new.operator_user_id,
    new.semantic_actor_ref_id,
    new.test_context_id
  );
  if v_context->>'mode' <> 'test_simulation' then
    raise exception 'TEST_DELIVERY_REQUIRES_TEST_CONTEXT';
  end if;
  return new;
end;
$$;

revoke all on function private.fn_enforce_test_delivery_scope()
  from public, anon, authenticated;
grant execute on function private.fn_enforce_test_delivery_scope()
  to service_role;

create trigger test_delivery_outbox_scope_guard
  before insert or update of household_id, test_context_id, operator_user_id, semantic_actor_ref_id
  on private.test_delivery_outbox
  for each row execute function private.fn_enforce_test_delivery_scope();

-- pending_actions.actor_id remains the authenticated operator provenance during
-- compatibility. actor_ref_id is the semantic domain actor. For test actions
-- these identities are intentionally allowed to differ, but the ActorRef/test
-- context must still be scoped to the same household/context.
create or replace function private.fn_enforce_pending_action_actor_scope()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform private.fn_assert_actor_ref_scope(
    new.household_id,
    new.actor_ref_id,
    new.test_context_id
  );

  if new.test_context_id is not null then
    perform private.fn_validate_execution_context_v1(
      new.household_id,
      new.actor_id,
      new.actor_ref_id,
      new.test_context_id
    );
  end if;
  return new;
end;
$$;

revoke all on function private.fn_enforce_pending_action_actor_scope()
  from public, anon, authenticated;
grant execute on function private.fn_enforce_pending_action_actor_scope()
  to service_role;

create trigger pending_actions_canonical_actor_scope_guard
  before insert or update of household_id, actor_id, actor_ref_id, test_context_id
  on private.pending_actions
  for each row execute function private.fn_enforce_pending_action_actor_scope();

-- mutation_receipts.actor_id remains operator/auth provenance. The semantic
-- ActorRef and test context are validated by deriving the ActorRef household;
-- this avoids overloading actor_id while keeping future test retries separate.
create or replace function private.fn_enforce_mutation_receipt_actor_scope()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
begin
  if new.actor_ref_id is null then
    if new.test_context_id is not null then
      raise exception 'TEST_MUTATION_RECEIPT_REQUIRES_ACTOR_REF';
    end if;
    return new;
  end if;

  select a.household_id into v_household_id
  from public.domain_actor_refs a
  where a.id = new.actor_ref_id;
  if not found then
    raise exception 'ACTOR_REF_NOT_FOUND';
  end if;

  perform private.fn_validate_execution_context_v1(
    v_household_id,
    new.actor_id,
    new.actor_ref_id,
    new.test_context_id
  );
  return new;
end;
$$;

revoke all on function private.fn_enforce_mutation_receipt_actor_scope()
  from public, anon, authenticated;
grant execute on function private.fn_enforce_mutation_receipt_actor_scope()
  to service_role;

create trigger mutation_receipts_canonical_actor_scope_guard
  before insert or update of actor_id, actor_ref_id, test_context_id
  on private.mutation_receipts
  for each row execute function private.fn_enforce_mutation_receipt_actor_scope();

revoke all on table private.canonical_operation_receipts from public, anon, authenticated;
revoke all on table private.test_delivery_outbox from public, anon, authenticated;
grant select, insert, update, delete on table private.canonical_operation_receipts to service_role;
grant select, insert, update, delete on table private.test_delivery_outbox to service_role;

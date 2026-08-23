-- A LINE text that process-line-inbox already classified as needs_pwa_review
-- has already received its reply-first clarification in that same worker.
-- Mark those rows as parse_failed at creation time so process-pending-actions
-- does not claim the same draft and send the same clarification a second time.
--
-- Keep ready_preview / explicit async draft states untouched: this only applies
-- to newly-created LINE needs_pwa_review rows without an existing state marker.

create or replace function public.server_tx_create_pending_action(
  p_actor_id uuid,
  p_household_id uuid,
  p_operation_id uuid,
  p_source text,
  p_action_type text,
  p_normalized_payload jsonb,
  p_ttl_minutes integer
)
returns jsonb
language plpgsql
set search_path to ''
as $$
declare
  v_id uuid;
  v_existing record;
  v_payload jsonb;
begin
  if p_actor_id is null or p_household_id is null or p_operation_id is null
     or coalesce(p_action_type, '') = '' or p_normalized_payload is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_source not in ('line', 'pwa') then
    raise exception 'INVALID_INPUT';
  end if;

  if not exists (
    select 1 from public.household_members
    where household_id = p_household_id and user_id = p_actor_id
  ) then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  v_payload := p_normalized_payload;
  if p_source = 'line'
     and p_action_type = 'needs_pwa_review'
     and not (v_payload ? 'line_intent_state') then
    v_payload := jsonb_set(v_payload, '{line_intent_state}', '"parse_failed"'::jsonb, true);
  end if;

  insert into private.pending_actions (
    household_id, actor_id, source, action_type, normalized_payload,
    operation_id, status, expires_at
  )
  values (
    p_household_id, p_actor_id, p_source, p_action_type, v_payload,
    p_operation_id, 'draft', now() + make_interval(mins => coalesce(p_ttl_minutes, 30))
  )
  on conflict (actor_id, operation_id) do nothing
  returning id into v_id;

  if v_id is not null then
    return jsonb_build_object('pending_action_id', v_id, 'status', 'draft', 'created', true);
  end if;

  select id, status into v_existing
  from private.pending_actions
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return jsonb_build_object('pending_action_id', v_existing.id, 'status', v_existing.status, 'created', false);
end;
$$;

-- Protect any not-yet-claimed rows created during rollout as well. This does
-- not delete or confirm user data; the draft remains visible in Judgment Wait.
update private.pending_actions
set normalized_payload = jsonb_set(
      normalized_payload,
      '{line_intent_state}',
      '"parse_failed"'::jsonb,
      true
    ),
    updated_at = now()
where source = 'line'
  and action_type = 'needs_pwa_review'
  and status = 'draft'
  and not (normalized_payload ? 'line_intent_state');
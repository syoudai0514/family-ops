-- Q4/Q70/Q71: LINE draft corrections must never let an older follow-up
-- overwrite a newer edit.  Add an explicit optimistic revision and make the
-- service-role edit contract require the revision observed with the draft.
-- Terminal state protection remains status-based; revision protects two
-- otherwise-valid draft edits racing each other.

alter table private.pending_actions
  add column if not exists revision bigint not null default 0;

do $$ begin
  alter table private.pending_actions
    add constraint pending_actions_revision_nonnegative check (revision >= 0);
exception when duplicate_object then null;
end $$;

-- Every read used as the basis of a LINE edit returns the same revision that
-- must be supplied to the guarded update below.
create or replace function public.server_tx_get_pending_action(
  p_actor_id uuid,
  p_pending_action_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare v_row record;
begin
  if p_actor_id is null or p_pending_action_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select id, action_type, normalized_payload, status, expires_at, revision
    into v_row
  from private.pending_actions
  where id = p_pending_action_id and actor_id = p_actor_id
  for update;

  if not found then raise exception 'PENDING_ACTION_NOT_EDITABLE'; end if;
  if v_row.status <> 'draft' or v_row.expires_at <= now() then
    raise exception 'PENDING_ACTION_NOT_EDITABLE';
  end if;

  return jsonb_build_object(
    'id', v_row.id,
    'action_type', v_row.action_type,
    'normalized_payload', v_row.normalized_payload,
    'status', v_row.status,
    'expires_at', v_row.expires_at,
    'revision', v_row.revision
  );
end;
$$;

create or replace function public.server_tx_get_line_pending_text_edit(
  p_actor_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare v_row record;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;

  select id, action_type, normalized_payload, status, expires_at, revision
    into v_row
  from private.pending_actions
  where actor_id = p_actor_id
    and source = 'line'
    and status = 'draft'
    and expires_at > now()
    and coalesce(normalized_payload->>'line_edit_mode', 'false') = 'true'
  order by updated_at desc, created_at desc
  limit 1;

  if not found then return null; end if;
  return jsonb_build_object(
    'id', v_row.id,
    'action_type', v_row.action_type,
    'normalized_payload', v_row.normalized_payload,
    'status', v_row.status,
    'expires_at', v_row.expires_at,
    'revision', v_row.revision
  );
end;
$$;

create or replace function public.server_tx_get_line_conversation_pending(
  p_actor_id uuid,
  p_line_user_id text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare v_row record;
begin
  if p_actor_id is null or coalesce(p_line_user_id, '') = '' then
    raise exception 'INVALID_INPUT';
  end if;

  update private.pending_actions pa
  set status = 'expired'
  from private.line_user_links link
  where pa.actor_id = p_actor_id
    and pa.source = 'line'
    and pa.status = 'draft'
    and pa.expires_at <= now()
    and link.user_id = pa.actor_id
    and link.household_id = pa.household_id
    and link.line_user_id = p_line_user_id
    and link.status = 'active';

  select pa.id, pa.household_id, pa.actor_id, pa.action_type,
         pa.normalized_payload, pa.status, pa.expires_at, pa.updated_at,
         pa.revision
    into v_row
  from private.pending_actions pa
  join private.line_user_links link
    on link.user_id = pa.actor_id
   and link.household_id = pa.household_id
   and link.line_user_id = p_line_user_id
   and link.status = 'active'
  where pa.actor_id = p_actor_id
    and pa.source = 'line'
  order by pa.updated_at desc, pa.created_at desc
  limit 1;

  if not found then return null; end if;
  return jsonb_build_object(
    'id', v_row.id,
    'household_id', v_row.household_id,
    'actor_id', v_row.actor_id,
    'action_type', v_row.action_type,
    'normalized_payload', v_row.normalized_payload,
    'status', v_row.status,
    'expires_at', v_row.expires_at,
    'updated_at', v_row.updated_at,
    'revision', v_row.revision
  );
end;
$$;

-- Remove the unguarded service API rather than leave a stale-write bypass.
drop function if exists public.server_tx_update_pending_action(uuid, uuid, text, jsonb);

create function public.server_tx_update_pending_action(
  p_actor_id uuid,
  p_pending_action_id uuid,
  p_action_type text,
  p_normalized_payload jsonb,
  p_expected_revision bigint
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_row record;
  v_state record;
begin
  if p_actor_id is null or p_pending_action_id is null
     or p_expected_revision is null or p_expected_revision < 0
     or p_action_type not in (
       'shopping_item_add', 'task_create_once', 'request_create',
       'assignment_change_request', 'line_multi_intent_review'
     )
     or p_normalized_payload is null
     or jsonb_typeof(p_normalized_payload) <> 'object' then
    raise exception 'INVALID_INPUT';
  end if;

  update private.pending_actions
  set action_type = p_action_type,
      normalized_payload = p_normalized_payload,
      revision = revision + 1,
      updated_at = now()
  where id = p_pending_action_id
    and actor_id = p_actor_id
    and source = 'line'
    and status = 'draft'
    and expires_at > now()
    and revision = p_expected_revision
  returning id, action_type, normalized_payload, status, expires_at, revision
    into v_row;

  if not found then
    select actor_id, source, status, expires_at, revision into v_state
    from private.pending_actions
    where id = p_pending_action_id;

    if not found or v_state.actor_id <> p_actor_id
       or v_state.source <> 'line'
       or v_state.status <> 'draft'
       or v_state.expires_at <= now() then
      raise exception 'PENDING_ACTION_NOT_EDITABLE';
    end if;
    if v_state.revision <> p_expected_revision then
      raise exception 'PENDING_ACTION_STALE';
    end if;
    raise exception 'PENDING_ACTION_NOT_EDITABLE';
  end if;

  return jsonb_build_object(
    'id', v_row.id,
    'action_type', v_row.action_type,
    'normalized_payload', v_row.normalized_payload,
    'status', v_row.status,
    'expires_at', v_row.expires_at,
    'revision', v_row.revision
  );
end;
$$;

revoke all on function public.server_tx_get_pending_action(uuid, uuid) from public, anon, authenticated;
revoke all on function public.server_tx_get_line_pending_text_edit(uuid) from public, anon, authenticated;
revoke all on function public.server_tx_get_line_conversation_pending(uuid, text) from public, anon, authenticated;
revoke all on function public.server_tx_update_pending_action(uuid, uuid, text, jsonb, bigint) from public, anon, authenticated;
grant execute on function public.server_tx_get_pending_action(uuid, uuid) to service_role;
grant execute on function public.server_tx_get_line_pending_text_edit(uuid) to service_role;
grant execute on function public.server_tx_get_line_conversation_pending(uuid, text) to service_role;
grant execute on function public.server_tx_update_pending_action(uuid, uuid, text, jsonb, bigint) to service_role;

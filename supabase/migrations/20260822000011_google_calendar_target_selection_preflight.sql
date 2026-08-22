-- Explicit target selection must validate the actor/household binding before
-- an Edge Function asks Google for live calendarList eligibility.  This is a
-- read-only preflight: it deliberately cannot clear an existing target.
create or replace function public.server_tx_get_google_calendar_target_candidate(
  p_actor_id uuid,
  p_calendar_connection_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_connection public.calendar_connections%rowtype;
begin
  if p_actor_id is null or p_calendar_connection_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;
  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  select * into v_connection
  from public.calendar_connections
  where id = p_calendar_connection_id
    and household_id = v_household_id
    and provider = 'google'
    and active
    and not reauth_required;
  if not found then
    -- Preserve server_tx_set_family_calendar_target's existing contract for
    -- inactive, reauth-required, or cross-household target candidates.
    raise exception 'INVALID_INPUT';
  end if;

  return jsonb_build_object(
    'household_id', v_household_id,
    'calendar_connection_id', v_connection.id,
    'external_calendar_id', v_connection.external_calendar_id
  );
end;
$$;

revoke all on function public.server_tx_get_google_calendar_target_candidate(uuid, uuid) from public, anon, authenticated;
grant execute on function public.server_tx_get_google_calendar_target_candidate(uuid, uuid) to service_role;

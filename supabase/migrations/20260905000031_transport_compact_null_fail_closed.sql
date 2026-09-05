-- Issue #48 final transport hardening: SQL three-valued logic must not let an
-- unresolved/cross-household actor through the compact P/M projection.
create or replace function private.family_ops_transport_compact_title(
  p_household_id uuid,
  p_dropoff_user_id uuid,
  p_pickup_user_id uuid
) returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_dropoff_token text;
  v_pickup_token text;
  v_title text := '';
begin
  if p_dropoff_user_id is not null then
    v_dropoff_token := private.family_ops_member_token(p_household_id,p_dropoff_user_id);
    if v_dropoff_token is null or v_dropoff_token not in ('P','M') then
      raise exception 'TRANSPORT_COMPACT_ACTOR_TOKEN_REQUIRED';
    end if;
    v_title := '送' || v_dropoff_token;
  end if;

  if p_pickup_user_id is not null then
    v_pickup_token := private.family_ops_member_token(p_household_id,p_pickup_user_id);
    if v_pickup_token is null or v_pickup_token not in ('P','M') then
      raise exception 'TRANSPORT_COMPACT_ACTOR_TOKEN_REQUIRED';
    end if;
    v_title := v_title || '迎' || v_pickup_token;
  end if;

  if v_title ~ '[[:space:]|｜/]' then
    raise exception 'TRANSPORT_COMPACT_TITLE_INVALID';
  end if;
  return v_title;
end;
$$;

revoke all on function private.family_ops_transport_compact_title(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function private.family_ops_transport_compact_title(uuid,uuid,uuid) to service_role;

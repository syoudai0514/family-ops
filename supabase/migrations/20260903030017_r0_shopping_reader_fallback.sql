-- R0 product compatibility for Shopping.
-- The authenticated adapter always consults the capability gate.  Until P1 it
-- shapes the established shopping_items truth directly and does not invoke the
-- canonical workspace reader.  This keeps the current PWA usable without
-- silently activating the P1 read model.

create or replace function public.get_my_shopping_workspace()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_active jsonb;
  v_history jsonb;
begin
  if v_actor_id is null then raise exception 'AUTH_REQUIRED'; end if;

  if private.fn_capability_reader_enabled_v1('shopping_responsibility_v2') then
    return public.server_read_shopping_workspace(v_actor_id);
  end if;

  select m.household_id into v_household_id
  from public.household_members m
  where m.user_id = v_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select a.id into v_actor_ref_id
  from public.domain_actor_refs a
  where a.household_id = v_household_id
    and a.actor_kind = 'real_user'
    and a.real_user_id = v_actor_id
    and a.test_context_id is null;

  with shaped as (
    select si.status, si.due_at, si.created_at,
      coalesce(si.arrived_at, si.purchased_at, si.ordered_at, si.created_at) as history_at,
      to_jsonb(si) || jsonb_build_object(
        'shopping_item_id', si.id,
        -- R0 keeps legacy responsibility semantics. Canonical anyone/claim
        -- responsibility becomes product-visible only after the reader gate.
        'assignment_mode', case when si.assignee_id is null then 'unassigned' else 'person' end,
        'assignee_actor_ref_id', null,
        'active_claimant_actor_ref_id', null,
        'claimed_at', null,
        'reader_mode', 'legacy_r0'
      ) as item
    from public.shopping_items si
    where si.household_id = v_household_id
      and si.test_context_id is null
  )
  select
    coalesce(jsonb_agg(item order by due_at nulls last, created_at)
      filter (where status in ('wanted','assigned','ordered')), '[]'::jsonb),
    coalesce(jsonb_agg(item order by history_at desc)
      filter (where status in ('purchased','arrived','cancelled')), '[]'::jsonb)
  into v_active, v_history
  from shaped;

  return jsonb_build_object(
    'generated_at', now(),
    'household_id', v_household_id,
    'actor_ref_id', v_actor_ref_id,
    'active', v_active,
    'history', v_history,
    'reader_mode', 'legacy_r0'
  );
end;
$$;
revoke all on function public.get_my_shopping_workspace() from public, anon;
grant execute on function public.get_my_shopping_workspace() to authenticated;

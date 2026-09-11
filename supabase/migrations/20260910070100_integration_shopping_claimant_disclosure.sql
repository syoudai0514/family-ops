-- Integration remediation for Appendix A Q107-Q109 / approved anyone-owner UX.
--
-- Preserve the CURRENT canonical Shopping workspace contract exactly and add
-- only the current real claimant's household profile display name. Ownership
-- truth remains shopping_items.active_claimant_actor_ref_id and release remains
-- explicit; no claim TTL/expiry semantics are introduced.

create or replace function public.server_read_shopping_workspace(p_actor_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare v_household_id uuid; v_actor_ref_id uuid; v_active jsonb; v_history jsonb;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;
  select household_id into v_household_id from public.household_members where user_id=p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select id into v_actor_ref_id from public.domain_actor_refs
    where household_id=v_household_id and actor_kind='real_user' and real_user_id=p_actor_id;
  with shaped as (
    select si.*,
      jsonb_build_object(
        'shopping_item_id',si.id,'title',si.title,'purchase_method',si.purchase_method,
        'status',si.status,'url',si.url,'due_at',si.due_at,
        'assignment_mode',coalesce(si.assignment_mode,case when si.assignee_id is null then 'unassigned' else 'person' end),
        'assignee_id',si.assignee_id,'assignee_actor_ref_id',si.assignee_actor_ref_id,
        'active_claimant_actor_ref_id',si.active_claimant_actor_ref_id,
        'active_claimant_display_name',claimant_profile.display_name,
        'claimed_at',si.claimed_at,
        'duplicate_sensitivity',coalesce(si.duplicate_sensitivity,'normal'),
        'performer_count',coalesce(actuals.performer_count,0),
        'performers',coalesce(actuals.performers,'[]'::jsonb),
        'household_completion_units',case when si.status in ('ordered','purchased','arrived') then 1 else 0 end,
        'revision',si.revision,
        'can_claim',coalesce(si.assignment_mode='anyone' and si.status='wanted' and si.active_claimant_actor_ref_id is null,false),
        'can_release',coalesce(si.active_claimant_actor_ref_id=v_actor_ref_id,false),
        'can_takeover',coalesce(si.assignment_mode='anyone' and si.status='wanted' and si.active_claimant_actor_ref_id<>v_actor_ref_id,false),
        'action_target',jsonb_build_object('kind','shopping','shopping_item_id',si.id,'revision',si.revision)
      ) item
    from public.shopping_items si
    left join public.domain_actor_refs claimant_actor
      on claimant_actor.household_id=si.household_id
     and claimant_actor.id=si.active_claimant_actor_ref_id
     and claimant_actor.actor_kind='real_user'
     and claimant_actor.test_context_id is null
    left join public.profiles claimant_profile
      on claimant_profile.user_id=claimant_actor.real_user_id
    left join lateral (
      select count(distinct sap.actor_ref_id)::int performer_count,
        jsonb_agg(jsonb_build_object(
          'actor_ref_id',sap.actor_ref_id,'real_user_id',ar.real_user_id,
          'actor_kind',ar.actor_kind,'simulated_role',ar.simulated_role,
          'action_kind',sap.action_kind,'recorded_at',sap.created_at,
          'recorded_by_actor_ref_id',sap.recorded_by_actor_ref_id
        ) order by sap.created_at,sap.id) performers
      from public.shopping_actual_participants sap
      join public.domain_actor_refs ar on ar.household_id=sap.household_id and ar.id=sap.actor_ref_id
      where sap.household_id=si.household_id and sap.shopping_item_id=si.id
        and sap.test_context_id is null and sap.removed_at is null
    ) actuals on true
    where si.household_id=v_household_id and si.test_context_id is null
  )
  select
    coalesce(jsonb_agg(item order by due_at nulls last,created_at)
      filter(where status in ('wanted','assigned','ordered')),'[]'::jsonb),
    coalesce(jsonb_agg(item order by coalesce(arrived_at,purchased_at,ordered_at,created_at) desc)
      filter(where status in ('purchased','arrived','cancelled')),'[]'::jsonb)
  into v_active,v_history from shaped;
  return jsonb_build_object('generated_at',now(),'household_id',v_household_id,
    'actor_ref_id',v_actor_ref_id,'active',v_active,'history',v_history,
    'writer_state','canonical_v1');
end; $$;
revoke all on function public.server_read_shopping_workspace(uuid)
  from public, anon, authenticated;
grant execute on function public.server_read_shopping_workspace(uuid) to service_role;

-- A typed restore retains earlier performers after completion is corrected or
-- recorded by somebody else. Only an active primary mirrors current truth.
\set ON_ERROR_STOP on
begin;
set local role service_role;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_partner uuid := gen_random_uuid();
  v_hh uuid;
  v_owner_actor uuid;
  v_partner_actor uuid;
  v_completed_task uuid := gen_random_uuid();
  v_skipped_task uuid := gen_random_uuid();
  v_history uuid := gen_random_uuid();
  v_removed_at timestamptz := now() - interval '1 minute';
begin
  insert into auth.users (id) values (v_owner), (v_partner);
  v_hh := (public.server_tx_create_household(
    v_owner, gen_random_uuid(), 'Participant recovery regression', 'Owner'
  )->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh, v_partner, 'adult');
  select id into v_owner_actor from public.domain_actor_refs
    where household_id = v_hh and real_user_id = v_owner;
  select id into v_partner_actor from public.domain_actor_refs
    where household_id = v_hh and real_user_id = v_partner;

  insert into public.task_instances (
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    completion_mode, status, actual_completed_by_id, completed_at, source, created_by
  ) values
    (v_completed_task, v_hh, 'manual', 'Completed by partner', 'other', 'anytime', current_date,
      'whole', 'completed', v_partner, now(), 'test', v_owner),
    (v_skipped_task, v_hh, 'manual', 'Earlier completion corrected', 'other', 'anytime', current_date,
      'whole', 'skipped', null, null, 'test', v_owner);

  -- Match the restore path: jsonb_populate_recordset inserts historical rows
  -- directly, without changing either task's current completion or actor IDs.
  insert into public.task_actual_participants
  select * from jsonb_populate_recordset(null::public.task_actual_participants,
    jsonb_build_array(
      jsonb_build_object('id', v_history, 'household_id', v_hh,
        'task_instance_id', v_completed_task, 'actor_ref_id', v_owner_actor,
        'participation_kind', 'performed', 'recorded_by_actor_ref_id', v_owner_actor,
        'recorded_at', v_removed_at, 'removed_at', v_removed_at,
        'removed_by_actor_ref_id', v_owner_actor, 'compatibility_primary', true,
        'source', 'canonical', 'created_at', v_removed_at),
      jsonb_build_object('id', gen_random_uuid(), 'household_id', v_hh,
        'task_instance_id', v_skipped_task, 'actor_ref_id', v_owner_actor,
        'participation_kind', 'performed', 'recorded_by_actor_ref_id', v_owner_actor,
        'recorded_at', v_removed_at, 'removed_at', v_removed_at,
        'removed_by_actor_ref_id', v_owner_actor, 'compatibility_primary', true,
        'source', 'canonical', 'created_at', v_removed_at)
    ));

  if (select count(*) from public.task_actual_participants
      where household_id = v_hh and actor_ref_id = v_owner_actor
        and compatibility_primary and removed_at = v_removed_at) <> 2
     or (select actual_completed_by_id from public.task_instances
         where id = v_completed_task) is distinct from v_partner then
    raise exception 'FAIL participant-recovery: historical fields or current performer changed';
  end if;

  begin
    update public.task_actual_participants
    set removed_at = null, removed_by_actor_ref_id = null where id = v_history;
    raise exception 'FAIL participant-recovery: invalid historical primary reactivated';
  exception when others then
    if sqlerrm <> 'COMPATIBILITY_PRIMARY_LEGACY_USER_MISMATCH' then raise; end if;
  end;

  begin
    insert into public.task_actual_participants (
      household_id, task_instance_id, actor_ref_id, compatibility_primary
    ) values (v_hh, v_completed_task, v_owner_actor, true);
    raise exception 'FAIL participant-recovery: mismatched active primary accepted';
  exception when others then
    if sqlerrm <> 'COMPATIBILITY_PRIMARY_LEGACY_USER_MISMATCH' then raise; end if;
  end;

  begin
    insert into public.task_actual_participants (
      household_id, task_instance_id, actor_ref_id, compatibility_primary
    ) values (v_hh, v_skipped_task, v_owner_actor, true);
    raise exception 'FAIL participant-recovery: active primary accepted without current performer';
  exception when others then
    if sqlerrm <> 'COMPATIBILITY_PRIMARY_LEGACY_USER_MISMATCH' then raise; end if;
  end;

  insert into public.task_actual_participants (
    household_id, task_instance_id, actor_ref_id, compatibility_primary
  ) values (v_hh, v_completed_task, v_partner_actor, true);
  if (select count(*) from public.task_actual_participants
      where task_instance_id = v_completed_task and removed_at is null
        and compatibility_primary and actor_ref_id = v_partner_actor) <> 1 then
    raise exception 'FAIL participant-recovery: matching current primary missing';
  end if;
end;
$$;

rollback;
select 'removed_participant_recovery: PASS' as result;

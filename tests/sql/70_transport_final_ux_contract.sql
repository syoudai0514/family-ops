-- Issue #48 final UX contract: compact transport presentation, period-scoped
-- weekly templates, occurrence-only overrides, and protected future agreements.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  u1 uuid := '70000000-0000-0000-0000-000000000001';
  u2 uuid := '70000000-0000-0000-0000-000000000002';
  u3 uuid := '70000000-0000-0000-0000-000000000003';
  h1 uuid; h2 uuid; token text; actor1 uuid; actor2 uuid;
  days_a jsonb; days_b jsonb; r_a jsonb; r_b jsonb; r_override jsonb;
  template_a uuid; template_b uuid; protected_task uuid; override_task uuid;
  before_day jsonb; after_day jsonb; failed boolean;
begin
  insert into auth.users(id) values(u1),(u2),(u3) on conflict do nothing;
  insert into public.profiles(user_id,display_name) values
    (u1,'Transport Papa'),(u2,'Transport Mama'),(u3,'Other Household')
    on conflict(user_id) do update set display_name=excluded.display_name;

  h1 := (public.server_tx_create_household(
    u1,'70000000-0000-0000-0000-000000000101','Transport UX H1','Papa'
  )->>'household_id')::uuid;
  token := public.server_tx_create_household_invite(
    u1,'70000000-0000-0000-0000-000000000102'
  )->>'raw_token';
  perform public.server_tx_join_household(
    u2,'70000000-0000-0000-0000-000000000103',token,'Mama'
  );
  h2 := (public.server_tx_create_household(
    u3,'70000000-0000-0000-0000-000000000104','Transport UX H2','Other'
  )->>'household_id')::uuid;

  if (select family_role from public.household_members where household_id=h1 and user_id=u1) <> 'papa'
     or (select family_role from public.household_members where household_id=h1 and user_id=u2) <> 'mama' then
    raise exception 'FAIL transport fixture family roles';
  end if;
  select id into actor1 from public.domain_actor_refs where household_id=h1 and actor_kind='real_user' and real_user_id=u1;
  select id into actor2 from public.domain_actor_refs where household_id=h1 and actor_kind='real_user' and real_user_id=u2;

  -- Exact compact representation. No whitespace or separator is ever present.
  if private.family_ops_transport_compact_title(h1,u1,u2) <> '送P迎M' then
    raise exception 'FAIL compact both';
  end if;
  if private.family_ops_transport_compact_title(h1,u1,null) <> '送P' then
    raise exception 'FAIL compact dropoff only';
  end if;
  if private.family_ops_transport_compact_title(h1,null,u2) <> '迎M' then
    raise exception 'FAIL compact pickup only';
  end if;
  if private.family_ops_transport_compact_title(h1,u1,u2) ~ '[[:space:]|｜/]' then
    raise exception 'FAIL compact separator/whitespace';
  end if;

  failed:=false;
  begin
    perform private.family_ops_transport_compact_title(h1,u3,null);
  exception when others then
    failed:=position('TRANSPORT_COMPACT_ACTOR_TOKEN_REQUIRED' in sqlerrm)>0;
  end;
  if not failed then raise exception 'FAIL compact cross-household/unknown actor did not fail closed'; end if;

  days_a := (
    select jsonb_agg(jsonb_build_object(
      'weekday',d,
      'dropoff_user_id',u1,
      'pickup_user_id',u2,
      'dropoff_local_time','08:00',
      'pickup_local_time','17:30'
    ) order by d) from generate_series(1,7) d
  );
  r_a := public.server_tx_save_transport_template(
    u1,'70000000-0000-0000-0000-000000000201','2026-09-01',days_a
  );
  template_a := (r_a->>'template_id')::uuid;
  if (r_a->>'valid_to') is not null then raise exception 'FAIL first template must be open-ended'; end if;
  if (select count(*) from public.transport_weekly_template_days where template_id=template_a)<>7 then
    raise exception 'FAIL first template is not one seven-day matrix';
  end if;

  -- Protect one future occurrence as an individually agreed assignment before
  -- introducing the next life-pattern template.
  select ti.id into protected_task
  from public.task_instances ti
  join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id
  where ti.household_id=h1 and td.code='dropoff' and ti.scheduled_date='2026-10-05';
  if protected_task is null then raise exception 'FAIL template did not materialize protected fixture occurrence'; end if;
  update public.task_instances
    set planned_assignee_id=u2,
        planned_assignee_actor_ref_id=actor2,
        assignment_mode='person',
        assignment_source='agreement',
        revision=revision+1
    where id=protected_task;

  days_b := (
    select jsonb_agg(jsonb_build_object(
      'weekday',d,
      'dropoff_user_id',u2,
      'pickup_user_id',u1,
      'dropoff_local_time','08:10',
      'pickup_local_time','17:40'
    ) order by d) from generate_series(1,7) d
  );
  r_b := public.server_tx_save_transport_template(
    u1,'70000000-0000-0000-0000-000000000202','2026-10-01',days_b
  );
  template_b := (r_b->>'template_id')::uuid;

  if (select valid_to from public.transport_weekly_templates where id=template_a) <> date '2026-09-30' then
    raise exception 'FAIL next template did not auto-close previous on prior day';
  end if;
  if (select valid_to from public.transport_weekly_templates where id=template_b) is not null then
    raise exception 'FAIL newest template must default open-ended';
  end if;
  if exists(
    select 1 from public.transport_weekly_templates a
    join public.transport_weekly_templates b on a.household_id=b.household_id and a.id<b.id
    where a.household_id=h1
      and daterange(a.valid_from,coalesce(a.valid_to,'infinity'::date),'[]') &&
          daterange(b.valid_from,coalesce(b.valid_to,'infinity'::date),'[]')
  ) then raise exception 'FAIL template periods overlap'; end if;
  if not exists(
    select 1 from jsonb_array_elements(coalesce(r_b->'protected_conflicts','[]'::jsonb)) x
    where x->>'task_id'=protected_task::text
  ) then raise exception 'FAIL protected individual agreement not surfaced'; end if;
  if not exists(
    select 1 from public.task_instances
    where id=protected_task and planned_assignee_id=u2 and planned_assignee_actor_ref_id=actor2
      and assignment_source='agreement'
  ) then raise exception 'FAIL new template silently overwrote protected individual agreement'; end if;

  -- Daily override changes exactly one occurrence; the weekly template row is
  -- unchanged. Deleting the override restores that date to Template B.
  select to_jsonb(d) into before_day
  from public.transport_weekly_template_days d
  where d.template_id=template_b and d.weekday=2;

  r_override := public.server_tx_set_transport_occurrence_override(
    u1,'70000000-0000-0000-0000-000000000203','2026-10-06',
    true,u1,false,null,'この日だけ送り交代'
  );
  if (r_override->>'override_id') is null then raise exception 'FAIL override id'; end if;
  select ti.id into override_task
  from public.task_instances ti
  join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id
  where ti.household_id=h1 and td.code='dropoff' and ti.scheduled_date='2026-10-06';
  if not exists(
    select 1 from public.task_instances
    where id=override_task and planned_assignee_id=u1 and assignment_source='occurrence_override'
      and source_context ? 'transport_occurrence_override'
  ) then raise exception 'FAIL occurrence override did not affect exactly target task'; end if;
  select to_jsonb(d) into after_day from public.transport_weekly_template_days d
    where d.template_id=template_b and d.weekday=2;
  if after_day is distinct from before_day then raise exception 'FAIL occurrence override mutated weekly template'; end if;
  if not exists(
    select 1 from public.task_events
    where task_instance_id=override_task and event_type='transport_override_applied'
  ) then raise exception 'FAIL override event identity'; end if;
  if exists(
    select 1 from public.task_events
    where task_instance_id=override_task and event_type='reassigned_once' and payload ? 'transport_override_id'
  ) then raise exception 'FAIL override masquerades as protected one-off agreement'; end if;

  perform public.server_tx_delete_transport_occurrence_override(
    u1,'70000000-0000-0000-0000-000000000204','2026-10-06'
  );
  if exists(select 1 from public.transport_occurrence_overrides where household_id=h1 and occurrence_date='2026-10-06') then
    raise exception 'FAIL override row not deleted';
  end if;
  if not exists(
    select 1 from public.task_instances
    where id=override_task and planned_assignee_id=u2 and assignment_source='legacy_snapshot'
      and not (source_context ? 'transport_occurrence_override')
  ) then raise exception 'FAIL deleting override did not restore base template'; end if;

  -- Same operation replay must not manufacture another template.
  if public.server_tx_save_transport_template(
      u1,'70000000-0000-0000-0000-000000000202','2026-10-01',days_b
    ) is distinct from r_b then
    raise exception 'FAIL template idempotent replay';
  end if;
  if (select count(*) from public.transport_weekly_templates where household_id=h1)<>2 then
    raise exception 'FAIL template replay duplicated period';
  end if;

  failed:=false;
  begin
    perform public.server_tx_save_transport_template(
      u1,'70000000-0000-0000-0000-000000000205','2026-11-01',
      jsonb_set(days_b,'{0,dropoff_user_id}',to_jsonb(u3::text))
    );
  exception when others then failed:=position('CROSS_HOUSEHOLD_RESOURCE' in sqlerrm)>0; end;
  if not failed then raise exception 'FAIL template accepted cross-household assignee'; end if;

  if h2 is null or actor1 is null then raise exception 'FAIL fixture integrity'; end if;
end;
$$;
reset role;
select '70_transport_final_ux_contract: PASS' as result;

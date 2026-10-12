-- Historical task snapshots retain their own classification, assignment and
-- revision during recovery. Normal writes still inherit current definitions
-- and project transport roles. Only three derivation triggers are suppressed;
-- validation triggers and foreign keys remain active throughout recovery.
\set ON_ERROR_STOP on
begin;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_household uuid;
  v_definition uuid;
  v_pickup_definition uuid;
  v_rule uuid := gen_random_uuid();
  v_normal uuid := gen_random_uuid();
  v_dependent uuid := gen_random_uuid();
  v_pickup uuid := gen_random_uuid();
  v_date date := date '2027-02-02'; -- Nonholiday Tuesday.
  v_expected_kind text;
  v_dependent_snapshot jsonb;
  v_pickup_snapshot jsonb;
  v_states jsonb;
  v_failed boolean := false;
  v_system_actor uuid;
  v_bad_snapshots jsonb[];
  v_expected_states text[] := array['P0001','23503','23514','P0001'];
  v_expected_errors text[] := array[
    'ACTOR_REF_NOT_IN_HOUSEHOLD',null,null,'SIMULATED_ACTOR_LEGACY_USER_SUBSTITUTION'
  ];
  v_error_state text;
  v_error_message text;
  v_case int;
  v_names text[] := array[
    'task_instances_copy_calendar_visibility',
    'task_instances_review_fix_domain',
    'task_transport_role_reconcile_insert'
  ];
  v_trigger text;
begin
  insert into auth.users(id) values(v_owner);
  v_household := (public.server_tx_create_household(
    v_owner, gen_random_uuid(), 'Recovery snapshot regression', 'Owner'
  )->>'household_id')::uuid;
  select id,task_kind into v_definition,v_expected_kind
  from public.task_definitions where household_id=v_household and code='dinner';
  select id into v_pickup_definition
  from public.task_definitions where household_id=v_household and code='pickup';
  if v_definition is null or v_pickup_definition is null or v_expected_kind='special' then
    raise exception 'FAIL recovery-snapshot: missing nonvacuous fixture definitions';
  end if;
  insert into public.recurrence_rules(
    id,household_id,task_definition_id,weekday,slot_key,assignee_strategy,
    effective_from,created_by
  ) values(v_rule,v_household,v_definition,2,'recovery-127','pickup_assignee',v_date,v_owner);

  -- A new occurrence follows the current definition, even if a caller supplies
  -- an old classification. The recovery exception must not change this path.
  insert into public.task_instances(
    id,household_id,task_definition_id,origin,title,category,routine_phase,
    scheduled_date,completion_mode,status,source,created_by,
    task_kind,calendar_visibility
  ) values(v_normal,v_household,v_definition,'manual','Current occurrence','household','evening',
    v_date,'whole','todo','test',v_owner,'special','special');
  if not exists(select 1 from public.task_instances where id=v_normal
    and task_kind=v_expected_kind and calendar_visibility='hidden') then
    raise exception 'FAIL recovery-snapshot: normal insertion lost current definition derivation';
  end if;

  insert into public.task_instances(
    id,household_id,task_definition_id,recurrence_rule_id,origin,title,category,
    routine_phase,scheduled_date,completion_mode,status,source,created_by
  ) values(v_dependent,v_household,v_definition,v_rule,'recurring','Historical occurrence',
    'household','evening',v_date,'whole','todo','test',v_owner);
  select to_jsonb(t)||jsonb_build_object(
    'task_kind','special','calendar_visibility','special','revision',17,
    'updated_at',timestamptz '2026-01-01 00:00:00+00'
  ) into v_dependent_snapshot from public.task_instances t where id=v_dependent;

  -- The live transport insertion really reassigns an unprotected dependent.
  -- Thus disabling this one AFTER trigger for recovery is not vacuous.
  insert into public.task_instances(
    id,household_id,task_definition_id,origin,title,category,routine_phase,
    scheduled_date,completion_mode,status,source,created_by,planned_assignee_id
  ) values(v_pickup,v_household,v_pickup_definition,'manual','Pickup','transport','evening',
    v_date,'whole','todo','test',v_owner,v_owner);
  if not exists(select 1 from public.task_instances where id=v_dependent
    and planned_assignee_id=v_owner and assignment_mode='person' and revision>1) then
    raise exception 'FAIL recovery-snapshot: normal transport role projection stopped working';
  end if;
  select to_jsonb(t) into v_pickup_snapshot from public.task_instances t where id=v_pickup;
  delete from public.task_instances where id=v_pickup;
  delete from public.task_events where household_id=v_household;
  delete from public.task_instances where id=v_dependent;

  select jsonb_object_agg(tgname,tgenabled::text order by tgname) into v_states
  from pg_trigger where tgrelid='public.task_instances'::regclass;
  if exists(select 1 from pg_trigger
    where tgrelid='public.task_instances'::regclass and tgname=any(v_names) and tgenabled<>'O')
    or (select count(*) from pg_trigger
        where tgrelid='public.task_instances'::regclass and tgname=any(v_names))<>3 then
    raise exception 'FAIL recovery-snapshot: required derivation triggers are not ordinarily enabled';
  end if;

  -- Transactional DDL rolls back with every rejected insertion. Actor scope,
  -- foreign keys, CHECK constraints and legacy compatibility remain enforced
  -- even while the three derivations are suppressed.
  v_system_actor := private.fn_household_system_actor_ref_v1(v_household);
  v_bad_snapshots := array[
    v_dependent_snapshot||jsonb_build_object(
      'id',gen_random_uuid(),'planned_assignee_actor_ref_id',gen_random_uuid()),
    v_dependent_snapshot||jsonb_build_object(
      'id',gen_random_uuid(),'task_definition_id',gen_random_uuid()),
    v_dependent_snapshot||jsonb_build_object('id',gen_random_uuid(),'revision',0),
    v_pickup_snapshot||jsonb_build_object(
      'id',gen_random_uuid(),'planned_assignee_actor_ref_id',v_system_actor,
      'assignment_source','manual')
  ];
  for v_case in 1..array_length(v_bad_snapshots,1) loop
    v_failed := false;
    begin
      foreach v_trigger in array v_names loop
        execute format('alter table public.task_instances disable trigger %I',v_trigger);
      end loop;
      insert into public.task_instances
      select * from jsonb_populate_recordset(null::public.task_instances,
        jsonb_build_array(v_bad_snapshots[v_case]));
      raise exception 'FAIL recovery-snapshot: invalid source row passed restore validation';
    exception when others then
      get stacked diagnostics v_error_state=returned_sqlstate,v_error_message=message_text;
      if v_error_state<>v_expected_states[v_case]
        or (v_expected_errors[v_case] is not null
          and v_error_message<>v_expected_errors[v_case]) then raise; end if;
      v_failed := true;
    end;
    if not v_failed or v_states is distinct from (
      select jsonb_object_agg(tgname,tgenabled::text order by tgname)
      from pg_trigger where tgrelid='public.task_instances'::regclass
    ) or (select count(*) from public.task_instances where household_id=v_household)<>1 then
      raise exception 'FAIL recovery-snapshot: rejected restore did not roll back trigger states and rows';
    end if;
  end loop;

  foreach v_trigger in array v_names loop
    execute format('alter table public.task_instances disable trigger %I',v_trigger);
  end loop;
  insert into public.task_instances
  select * from jsonb_populate_recordset(null::public.task_instances,
    jsonb_build_array(v_dependent_snapshot,v_pickup_snapshot));
  foreach v_trigger in array v_names loop
    execute format('alter table public.task_instances enable trigger %I',v_trigger);
  end loop;

  if v_dependent_snapshot is distinct from (
      select to_jsonb(t) from public.task_instances t where id=v_dependent)
    or v_pickup_snapshot is distinct from (
      select to_jsonb(t) from public.task_instances t where id=v_pickup)
    or exists(select 1 from public.task_events where household_id=v_household)
    or v_states is distinct from (
      select jsonb_object_agg(tgname,tgenabled::text order by tgname)
      from pg_trigger where tgrelid='public.task_instances'::regclass) then
    raise exception 'FAIL recovery-snapshot: recovery changed historical fields, generated audit, or left triggers suppressed';
  end if;
end;
$$;

rollback;
select 'recovery_task_snapshot_preservation: PASS' as result;

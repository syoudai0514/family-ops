\set ON_ERROR_STOP on
begin;
do $$
declare a uuid:=gen_random_uuid(); h uuid; task uuid; state jsonb; failed boolean;
begin
  insert into auth.users(id) values(a);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'archive storage','A')->>'household_id')::uuid;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,
    assignment_mode,completion_mode,status,source,created_by)
    values(h,'recurring','記録のない作業','household','morning',current_date-1,'unassigned','whole','todo','test',a) returning id into task;
  state:=jsonb_build_object('status','todo','attention_state','active','active_claimant_actor_ref_id',null,
    'claimed_at',null,'waiting_note',null,'next_check_at',null,'outcome_reason',null,'rescheduled_to',null,
    'actual_completed_by_id',null,'completed_at',null);
  failed:=false;
  begin
    update public.task_instances set outcome_reason='unrecorded' where id=task;
  exception when check_violation then failed:=true; end;
  if not failed then raise exception 'an open task was marked unrecorded'; end if;
  failed:=false;
  begin
    insert into private.unrecorded_routine_archives(household_id,task_id,before_revision,closed_revision,before_state)
      values(h,task,1,3,state);
  exception when check_violation then failed:=true; end;
  if not failed then raise exception 'non-consecutive revisions accepted'; end if;
  failed:=false;
  begin
    insert into private.unrecorded_routine_archives(household_id,task_id,before_revision,closed_revision,before_state)
      values(h,task,1,2,state-'claimed_at');
  exception when check_violation then failed:=true; end;
  if not failed then raise exception 'incomplete pre-close state accepted'; end if;
  update public.task_instances set status='skipped',outcome_reason='unrecorded',revision=revision+1 where id=task;
  insert into private.unrecorded_routine_archives(household_id,task_id,before_revision,closed_revision,before_state)
    values(h,task,1,2,state);
  if (select before_state from private.unrecorded_routine_archives where household_id=h and task_id=task) is distinct from state then
    raise exception 'pre-close state lost'; end if;
  if has_table_privilege('anon','private.unrecorded_routine_archives','select')
    or has_table_privilege('authenticated','private.unrecorded_routine_archives','select')
    or has_table_privilege('service_role','private.unrecorded_routine_archives','select')
    or not (select relrowsecurity from pg_class where oid='private.unrecorded_routine_archives'::regclass) then
    raise exception 'archive storage exposed'; end if;
end $$;
rollback;
select 'unrecorded_archive_storage: PASS' as result;

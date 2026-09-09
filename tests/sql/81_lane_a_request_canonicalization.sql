\set ON_ERROR_STOP on
begin;
-- Inject an actual SQL failure after assignment mutation, before commit.
create function private.lane_a_inject_failure() returns trigger language plpgsql as $$
begin
 if current_setting('lane_a.inject_failure',true)='on' and new.event_type='assignment_agreed' then
   raise exception 'LANE_A_INJECTED_FAILURE';
 end if;
 return new;
end; $$;
create trigger lane_a_inject_failure before insert on public.task_events
for each row execute function private.lane_a_inject_failure();
set role service_role;
do $$
declare u uuid:=gen_random_uuid(); v uuid:=gen_random_uuid(); hh uuid; ar uuid; br uuid; task_id uuid;
 c jsonb; result jsonb; replay jsonb; req uuid; attempt uuid; op uuid; terms jsonb; phase text; channel text;
 count_before integer; work_due timestamptz; reply_due timestamptz;
begin
 insert into auth.users(id) values(u),(v);
 hh:=(public.server_tx_create_household(u,gen_random_uuid(),'Lane A test','Owner')->>'household_id')::uuid;
 insert into public.household_members(household_id,user_id,member_role) values(hh,v,'adult');
 perform private.backfill_canonical_foundation_v1();
 select id into ar from public.domain_actor_refs where household_id=hh and real_user_id=u;
 select id into br from public.domain_actor_refs where household_id=hh and real_user_id=v;
 foreach channel in array array['pwa','line'] loop
   foreach phase in array array['pending','checking','consulting','declined','expired','atomicity','stale_task'] loop
     insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,
       completion_mode,status,source,created_by,assignment_mode,assignment_source,planned_assignee_actor_ref_id,due_at)
     values(hh,'manual','Lane A '||phase,'other','anytime',current_date,u,'whole','todo','lane_a_test',u,'person','manual',ar,now()+interval '4 days')
     returning id into task_id;
     c:=public.server_tx_create_assignment_change_request(u,gen_random_uuid(),task_id,v,'代われますか','once');
     req:=(c->>'request_id')::uuid; attempt:=(c->>'attempt_id')::uuid;
     if c->>'state'<>'pending' or (select planned_assignee_actor_ref_id from public.task_instances where id=task_id)<>ar then
       raise exception 'FAIL create mutated assignment'; end if;
     if (select request_kind from public.requests where id=req)<>'assignment_change' then raise exception 'FAIL wrong kind'; end if;
     if exists(select 1 from public.assignment_change_request_tasks where request_id=req) then raise exception 'FAIL legacy scope written'; end if;
     if phase='checking' then
       perform public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'checking',null,1,1,channel);
       if (select planned_assignee_actor_ref_id from public.task_instances where id=task_id)<>ar then raise exception 'FAIL checking assigned'; end if;
       begin
         perform public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'accept',null,1,1,'line');
         raise exception 'FAIL stale LINE revision accepted';
       exception when others then if sqlerrm<>'REQUEST_ATTEMPT_STALE' then raise; end if; end;
       result:=public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'accept',null,2,1,channel);
     elsif phase='consulting' then
       perform public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'consult',null,1,1,channel);
       select a.terms into terms from public.request_attempts a where id=attempt;
       result:=public.server_tx_transition_request_v2(u,gen_random_uuid(),req,attempt,'edit_terms',terms||'{"candidate":"相談確認"}',2,1,channel);
       if result->>'state'<>'awaiting_confirmation' or (select planned_assignee_actor_ref_id from public.task_instances where id=task_id)<>ar then
         raise exception 'FAIL one-sided terms confirmation assigned'; end if;
       begin
         perform public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'confirm_terms',null,3,1,channel);
         raise exception 'FAIL stale terms accepted';
       exception when others then if sqlerrm<>'REQUEST_TERMS_REVISION_STALE' then raise; end if; end;
       result:=public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'confirm_terms',null,3,2,channel);
     elsif phase='declined' then
       result:=public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'decline',null,1,1,channel);
       if result->>'state'<>'declined' then raise exception 'FAIL decline'; end if;
     elsif phase='expired' then
       update public.request_attempts set reply_due_at=now()-interval '1 minute' where id=attempt;
       result:=public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'accept',null,1,1,channel);
       if result->>'state'<>'expired' or result->>'reproposal_required'<>'true' then raise exception 'FAIL expired revival'; end if;
       if (select planned_assignee_actor_ref_id from public.task_instances where id=task_id)<>ar then raise exception 'FAIL expired assignment'; end if;
     elsif phase='stale_task' then
       update public.task_instances set revision=revision+1 where id=task_id;
       begin
         perform public.server_tx_transition_request_v2(v,gen_random_uuid(),req,attempt,'accept',null,1,1,channel);
         raise exception 'FAIL stale task accepted';
       exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
       if (select state from public.request_attempts where id=attempt)<>'pending' then raise exception 'FAIL stale task half applied'; end if;
       continue;
     else
       op:=gen_random_uuid();
       if phase='atomicity' then
         perform set_config('lane_a.inject_failure','on',true);
         begin
           perform public.server_tx_transition_request_v2(v,op,req,attempt,'accept',null,1,1,channel);
           raise exception 'FAIL injected failure missed';
         exception when others then if sqlerrm<>'LANE_A_INJECTED_FAILURE' then raise; end if; end;
         perform set_config('lane_a.inject_failure','off',true);
         if (select state from public.request_attempts where id=attempt)<>'pending'
           or (select planned_assignee_actor_ref_id from public.task_instances where id=task_id)<>ar
           or exists(select 1 from public.task_events where payload->>'attempt_id'=attempt::text) then
           raise exception 'FAIL transaction left partial state'; end if;
       end if;
       result:=public.server_tx_transition_request_v2(v,op,req,attempt,'accept',null,1,1,channel);
       select count(*) into count_before from public.user_notifications where household_id=hh;
       replay:=public.server_tx_transition_request_v2(v,op,req,attempt,'accept',null,1,1,channel);
       if result<>replay or count_before<>(select count(*) from public.user_notifications where household_id=hh) then
         raise exception 'FAIL operation replay duplicated mutation/notification'; end if;
     end if;
     if phase not in ('declined','expired') then
       if result->>'state'<>'accepted' or (select planned_assignee_actor_ref_id from public.task_instances where id=task_id)<>br
          or (select planned_assignee_id from public.task_instances where id=task_id)<>v
          or (select assignment_source from public.task_instances where id=task_id)<>'agreement'
          or (select linked_task_instance_id from public.requests where id=req)<>task_id then
         raise exception 'FAIL canonical assignment/projection/link mismatch'; end if;
       if (select count(*) from public.task_events where payload->>'attempt_id'=attempt::text)<>1 then
         raise exception 'FAIL audit missing or duplicated'; end if;
     elsif (select planned_assignee_actor_ref_id from public.task_instances where id=task_id)<>ar then
       raise exception 'FAIL terminal unsuccessful changed assignment';
     end if;
   end loop;
 end loop;
 -- Work and reply order must be independent; expired work does not expire a
 -- still-valid response deadline. No channel-specific proposal rule.
 for work_due,reply_due in select * from (values
  (now()+interval '4 days',now()+interval '1 day'),
  (now()+interval '1 day',now()+interval '4 days'),
  (now()-interval '1 day',now()+interval '1 day'),
  (null::timestamptz,null::timestamptz)) fixture(work_due,reply_due)
 loop
   c:=private.fn_command_create_light_request_v2(hh,u,ar,null,br,'Deadline fixture',null,work_due,reply_due,gen_random_uuid(),'pwa');
   if (c->>'reply_due_at')::timestamptz is distinct from coalesce(reply_due,now()+interval '24 hours') then
     raise exception 'FAIL reply proposal or override'; end if;
   result:=public.server_tx_transition_request_v2(v,gen_random_uuid(),(c->>'request_id')::uuid,(c->>'attempt_id')::uuid,'accept',null,1,1,'line');
   if result->>'state'<>'accepted' then raise exception 'FAIL work deadline affected reply lifecycle'; end if;
 end loop;
end; $$;
rollback;

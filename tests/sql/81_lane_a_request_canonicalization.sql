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
declare
 u uuid:=gen_random_uuid(); v uuid:=gen_random_uuid(); hh uuid; ar uuid; br uuid; task_id uuid;
 c jsonb; result jsonb; replay jsonb; req uuid; attempt uuid; op uuid; terms jsonb; phase text; channel text;
 count_before integer; work_due timestamptz; reply_due timestamptz; actual_reply timestamptz;
 next_tuesday timestamptz; next_friday timestamptz; anchor_before timestamptz;
 line_accept_op uuid; line_payload jsonb;
begin
 insert into auth.users(id) values(u),(v);
 hh:=(public.server_tx_create_household(u,gen_random_uuid(),'Lane A test','Owner')->>'household_id')::uuid;
 insert into public.household_members(household_id,user_id,member_role) values(hh,v,'adult');
 perform private.backfill_canonical_foundation_v1();
 select id into ar from public.domain_actor_refs where household_id=hh and real_user_id=u;
 select id into br from public.domain_actor_refs where household_id=hh and real_user_id=v;

 -- CF-01: the same RequestAttempt transition contract is exercised from both
 -- PWA and LINE sources for every material assignment lifecycle branch.
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

 -- CF-12 explicit order cases. Build next week's Tuesday / Friday in JST so
 -- the fixture remains future-dated instead of becoming an accidental expiry
 -- test as wall-clock time advances.
 next_tuesday := (
   date_trunc('week', now() at time zone 'Asia/Tokyo') + interval '8 days 12 hours'
 ) at time zone 'Asia/Tokyo';
 next_friday := (
   date_trunc('week', now() at time zone 'Asia/Tokyo') + interval '11 days 12 hours'
 ) at time zone 'Asia/Tokyo';

 -- reply Tuesday / work Friday
 c:=private.fn_command_create_light_request_v2(
   hh,u,ar,null,br,'Reply Tue work Fri',null,next_friday,next_tuesday,gen_random_uuid(),'pwa');
 if (c->>'reply_due_at')::timestamptz is distinct from next_tuesday
    or (c->>'due_at')::timestamptz is distinct from next_friday then
   raise exception 'FAIL reply Tue/work Fri collapsed deadlines'; end if;
 result:=public.server_tx_transition_request_v2(v,gen_random_uuid(),(c->>'request_id')::uuid,(c->>'attempt_id')::uuid,'accept',null,1,1,'line');
 if result->>'state'<>'accepted' then raise exception 'FAIL reply Tue/work Fri LINE acceptance'; end if;

 -- reply Friday / work Tuesday: an explicit future response deadline is
 -- allowed after the work deadline; work due must not expire the Attempt.
 c:=private.fn_command_create_light_request_v2(
   hh,u,ar,null,br,'Reply Fri work Tue',null,next_tuesday,next_friday,gen_random_uuid(),'pwa');
 if (c->>'reply_due_at')::timestamptz is distinct from next_friday
    or (c->>'due_at')::timestamptz is distinct from next_tuesday then
   raise exception 'FAIL reply Fri/work Tue collapsed deadlines'; end if;
 result:=public.server_tx_transition_request_v2(v,gen_random_uuid(),(c->>'request_id')::uuid,(c->>'attempt_id')::uuid,'accept',null,1,1,'line');
 if result->>'state'<>'accepted' then raise exception 'FAIL work deadline affected response lifecycle'; end if;

 -- Omitted reply deadline with future work: server proposes and persists one
 -- response deadline, no caller-specific fallback. It must be future, no more
 -- than 24h from the creation anchor, and earlier than the Friday work due.
 anchor_before:=clock_timestamp();
 c:=private.fn_command_create_light_request_v2(
   hh,u,ar,null,br,'Omitted reply with work',null,next_friday,null,gen_random_uuid(),'pwa');
 actual_reply:=(c->>'reply_due_at')::timestamptz;
 if actual_reply is null or actual_reply <= anchor_before
    or actual_reply > anchor_before + interval '24 hours 5 seconds'
    or actual_reply >= next_friday then
   raise exception 'FAIL omitted reply deadline proposal'; end if;
 if (select reply_due_at from public.request_attempts where id=(c->>'attempt_id')::uuid) is distinct from actual_reply then
   raise exception 'FAIL proposed reply deadline not persisted as Attempt truth'; end if;

 -- Omitted reply and work deadline still gets a response deadline (~24h).
 anchor_before:=clock_timestamp();
 c:=private.fn_command_create_light_request_v2(
   hh,u,ar,null,br,'Omitted both deadlines',null,null,null,gen_random_uuid(),'pwa');
 actual_reply:=(c->>'reply_due_at')::timestamptz;
 if actual_reply < anchor_before + interval '23 hours 59 minutes'
    or actual_reply > anchor_before + interval '24 hours 5 seconds' then
   raise exception 'FAIL omitted reply/work proposal'; end if;

 -- Public light-request creation must propagate the *persisted* proposed reply
 -- deadline and immutable Attempt snapshot into LINE pending actions.
 c:=public.server_tx_send_request_v2(
   u,gen_random_uuid(),v,'LINE snapshot parity','お願いします',next_friday,null);
 req:=(c->>'request_id')::uuid; attempt:=(c->>'attempt_id')::uuid;
 actual_reply:=(c->>'reply_due_at')::timestamptz;
 select operation_id, normalized_payload into line_accept_op, line_payload
 from private.pending_actions
 where actor_id=v and action_type='request_accept'
   and normalized_payload->>'request_id'=req::text;
 if line_accept_op is null
    or line_payload->>'attempt_id' is distinct from attempt::text
    or (line_payload->>'expected_revision')::bigint <> 1
    or (line_payload->>'expected_terms_revision')::integer <> 1
    or (line_payload->>'reply_due_at')::timestamptz is distinct from actual_reply then
   raise exception 'FAIL LINE action missing immutable RequestAttempt snapshot'; end if;
 if not exists(
   select 1 from public.user_notifications n
   where n.recipient_user_id=v
     and n.dedup_key='request:received:'||req::text
     and (n.payload->>'reply_due_at')::timestamptz is not distinct from actual_reply
     and n.payload->>'attempt_id'=attempt::text
 ) then raise exception 'FAIL LINE notification lost persisted reply deadline/snapshot'; end if;

 -- If the Attempt changes after the LINE button was issued, the worker's
 -- legacy adapter must consume the stored snapshot and fail stale rather than
 -- selecting the newer revision on the user's behalf.
 update public.request_attempts set revision=revision+1 where id=attempt;
 begin
   perform public.server_tx_accept_request(v,line_accept_op,req);
   raise exception 'FAIL stale LINE pending action accepted latest revision';
 exception when others then if sqlerrm<>'REQUEST_ATTEMPT_STALE' then raise; end if; end;

 -- Fresh LINE pending action succeeds through the same canonical transition.
 c:=public.server_tx_send_request_v2(
   u,gen_random_uuid(),v,'LINE fresh snapshot','お願いします',next_friday,next_tuesday);
 req:=(c->>'request_id')::uuid; attempt:=(c->>'attempt_id')::uuid;
 select operation_id into line_accept_op
 from private.pending_actions
 where actor_id=v and action_type='request_accept'
   and normalized_payload->>'request_id'=req::text;
 result:=public.server_tx_accept_request(v,line_accept_op,req);
 if result->>'state'<>'accepted'
    or (select state from public.request_attempts where id=attempt)<>'accepted' then
   raise exception 'FAIL fresh LINE snapshot did not use canonical transition'; end if;
end; $$;
rollback;

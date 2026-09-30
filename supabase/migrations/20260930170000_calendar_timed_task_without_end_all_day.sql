-- Owner decision 2026-09-30 (Requirements §29.11, option A): a special task with a time
-- but no end time is mirrored to Google Calendar as an all-day event on its date, with
-- the time at the head of the title ("8:00 食育の準備"). Live: "食育の準備（すだちぐみ
-- 食育）", registered over LINE with 08:00 and no end, could not be mirrored at all.
-- No end time is invented. A task that does have an end time is still a timed event;
-- an end at or before the start is still refused (and parked, see 20260930150000).

create or replace function public.server_tx_claim_family_ops_calendar_mirror(p_worker_id text, p_lease_seconds integer default 120)
 returns jsonb
 language plpgsql
 set search_path to ''
as $function$
declare
  v_mirror private.family_ops_calendar_mirrors%rowtype;
  v_lease uuid;
  v_dropoff uuid;
  v_pickup uuid;
  v_task public.task_instances%rowtype;
  v_title text;
  v_payload jsonb;
  v_event_id text;
  v_skipped integer := 0;
begin
  if coalesce(p_worker_id,'')='' then raise exception 'INVALID_INPUT'; end if;

  -- Bounded: a burst of invalid rows is parked a few at a time, never looped forever.
  while v_skipped < 10 loop
    v_lease := gen_random_uuid();
    select * into v_mirror
    from private.family_ops_calendar_mirrors
    where (sync_state in ('pending','failed') and next_attempt_at<=now())
       or (sync_state='processing' and lease_until<now())
    order by next_attempt_at,updated_at
    for update skip locked
    limit 1;
    if not found then return null; end if;

    update private.family_ops_calendar_mirrors
    set sync_state='processing',lease_token=v_lease,
        lease_until=now()+make_interval(secs=>greatest(coalesce(p_lease_seconds,120),30)),
        attempts=attempts+1,updated_at=now()
    where household_id=v_mirror.household_id and projection_key=v_mirror.projection_key
    returning * into v_mirror;

    v_event_id:=coalesce(v_mirror.provider_event_id,
      'fo'||substr(md5(v_mirror.household_id::text||':'||v_mirror.projection_key),1,32));

    if v_mirror.desired_action='delete' then
      return jsonb_build_object(
        'household_id',v_mirror.household_id,'projection_key',v_mirror.projection_key,
        'calendar_connection_id',v_mirror.calendar_connection_id,'lease_token',v_lease,
        'action','delete','provider_event_id',v_mirror.provider_event_id,
        'deterministic_event_id',v_event_id
      );
    end if;

    begin
      if v_mirror.kind='transport' then
        select ti.planned_assignee_id into v_dropoff
        from public.task_instances ti join public.task_definitions td
          on td.household_id=ti.household_id and td.id=ti.task_definition_id
        where ti.household_id=v_mirror.household_id and ti.scheduled_date=v_mirror.local_date
          and ti.status<>'cancelled' and td.code='dropoff'
          and ti.test_context_id is null
        order by ti.updated_at desc,ti.id desc limit 1;

        select ti.planned_assignee_id into v_pickup
        from public.task_instances ti join public.task_definitions td
          on td.household_id=ti.household_id and td.id=ti.task_definition_id
        where ti.household_id=v_mirror.household_id and ti.scheduled_date=v_mirror.local_date
          and ti.status<>'cancelled' and td.code='pickup'
          and ti.test_context_id is null
        order by ti.updated_at desc,ti.id desc limit 1;

        if v_dropoff is null and v_pickup is null then
          return jsonb_build_object(
            'household_id',v_mirror.household_id,'projection_key',v_mirror.projection_key,
            'calendar_connection_id',v_mirror.calendar_connection_id,'lease_token',v_lease,
            'action','delete','provider_event_id',v_mirror.provider_event_id,
            'deterministic_event_id',v_event_id
          );
        end if;

        v_title:=private.family_ops_transport_compact_title(v_mirror.household_id,v_dropoff,v_pickup);
        if v_title='' or v_title ~ '[[:space:]|｜/]' then raise exception 'TRANSPORT_COMPACT_TITLE_INVALID'; end if;
        if v_dropoff is not null and position('送' in v_title)=0 then raise exception 'TRANSPORT_COMPACT_ACTOR_TOKEN_REQUIRED'; end if;
        if v_pickup is not null and position('迎' in v_title)=0 then raise exception 'TRANSPORT_COMPACT_ACTOR_TOKEN_REQUIRED'; end if;

        v_payload:=jsonb_build_object(
          'id',v_event_id,'summary',v_title,
          'start',jsonb_build_object('date',v_mirror.local_date::text),
          'end',jsonb_build_object('date',(v_mirror.local_date+1)::text),
          'transparency','transparent'
        );
      else
        select * into v_task from public.task_instances
        where household_id=v_mirror.household_id and id=v_mirror.task_instance_id;
        if not found or v_task.test_context_id is not null
           or v_task.status='cancelled' or v_task.calendar_visibility<>'special' then
          return jsonb_build_object(
            'household_id',v_mirror.household_id,'projection_key',v_mirror.projection_key,
            'calendar_connection_id',v_mirror.calendar_connection_id,'lease_token',v_lease,
            'action','delete','provider_event_id',v_mirror.provider_event_id,
            'deterministic_event_id',v_event_id
          );
        end if;
        if v_task.calendar_ends_at is not null and v_task.calendar_ends_at<=v_task.due_at then
          raise exception 'INVALID_INPUT';
        end if;
        if v_task.due_at is null then
          v_payload:=jsonb_build_object(
            'id',v_event_id,'summary',v_task.title,
            'start',jsonb_build_object('date',v_task.scheduled_date::text),
            'end',jsonb_build_object('date',(v_task.scheduled_date+1)::text),
            'transparency','transparent'
          );
        elsif v_task.calendar_ends_at is null then
          -- A time without an end time (typically a deadline, "8:00までに準備"):
          -- all day on its date, the time at the head of the title. No end time is
          -- invented (owner decision 2026-09-30, Requirements §29.11 option A).
          v_payload:=jsonb_build_object(
            'id',v_event_id,
            'summary',to_char(v_task.due_at at time zone 'Asia/Tokyo','FMHH24:MI')||' '||v_task.title,
            'start',jsonb_build_object('date',v_task.scheduled_date::text),
            'end',jsonb_build_object('date',(v_task.scheduled_date+1)::text),
            'transparency','transparent'
          );
        else
          v_payload:=jsonb_build_object(
            'id',v_event_id,'summary',v_task.title,
            'start',jsonb_build_object('dateTime',v_task.due_at,'timeZone','Asia/Tokyo'),
            'end',jsonb_build_object('dateTime',v_task.calendar_ends_at,'timeZone','Asia/Tokyo')
          );
        end if;
      end if;

      v_payload:=v_payload||jsonb_build_object('extendedProperties',jsonb_build_object('private',jsonb_build_object(
        'familyOpsMirror','true','familyOpsProjectionKey',v_mirror.projection_key,
        'familyOpsKind',v_mirror.kind,
        'familyOpsTaskInstanceId',coalesce(v_mirror.task_instance_id::text,'')
      )));
      return jsonb_build_object(
        'household_id',v_mirror.household_id,'projection_key',v_mirror.projection_key,
        'calendar_connection_id',v_mirror.calendar_connection_id,'lease_token',v_lease,
        'action','upsert','provider_event_id',v_mirror.provider_event_id,
        'deterministic_event_id',v_event_id,'event',v_payload
      );
    exception when raise_exception then
      -- The row cannot be mirrored as it stands. Park it with the reason (same backoff
      -- as a provider failure) and move on; editing the task re-queues it as pending.
      update private.family_ops_calendar_mirrors
      set sync_state='failed',lease_token=null,lease_until=null,
          last_error=left(sqlerrm,1000),
          next_attempt_at=now()+make_interval(secs=>(2^least(v_mirror.attempts,6))::integer*30),
          updated_at=now()
      where household_id=v_mirror.household_id and projection_key=v_mirror.projection_key;
      v_skipped := v_skipped + 1;
    end;
  end loop;
  return null;
end;
$function$;

revoke all on function public.server_tx_claim_family_ops_calendar_mirror(text,integer) from public,anon,authenticated;
grant execute on function public.server_tx_claim_family_ops_calendar_mirror(text,integer) to service_role;

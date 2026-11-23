-- Dormant foundation for #200. This migration alone does not suppress a
-- notification or send an agreement prompt. Offers and acceptances are scoped
-- to an individual recipient and to exact, server-computed rule contents.
create table private.assignment_consent_offers (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null,
  recipient_id uuid not null,
  kind text not null check(kind in ('rule','transport')),
  target_id uuid not null,
  snapshot jsonb not null check(jsonb_typeof(snapshot)='object'),
  status text not null default 'pending' check(status in ('pending','agreed','change_requested','later')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  foreign key(household_id,recipient_id) references public.household_members(household_id,user_id) on delete cascade
);
create index assignment_consent_offers_recipient_idx
  on private.assignment_consent_offers(household_id,recipient_id,created_at desc);
alter table private.assignment_consent_offers enable row level security;
revoke all on private.assignment_consent_offers from public,anon,authenticated;

create table private.assignment_consents (
  household_id uuid not null,
  recipient_id uuid not null,
  kind text not null check(kind in ('rule','transport')),
  target_id uuid not null,
  snapshot jsonb not null check(jsonb_typeof(snapshot)='object'),
  offer_id uuid not null references private.assignment_consent_offers(id),
  agreed_at timestamptz not null default now(),
  primary key(household_id,recipient_id,kind,target_id),
  foreign key(household_id,recipient_id) references public.household_members(household_id,user_id) on delete cascade
);
alter table private.assignment_consents enable row level security;
revoke all on private.assignment_consents from public,anon,authenticated;

-- A snapshot includes every field that changes the meaning of a rule, not
-- just the existing version column (several legacy writers update rows in
-- place without incrementing version). Subtask contents are part of the
-- commitment. For transport, revision and the recipient's full weekly plan
-- are captured; editing a template never reuses the previous acceptance.
create function private.fn_assignment_consent_snapshot_v1(
  p_household_id uuid,p_recipient_id uuid,p_kind text,p_target_id uuid
) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; today date:=(now() at time zone 'Asia/Tokyo')::date;
begin
  if not exists(select 1 from public.household_members where household_id=p_household_id and user_id=p_recipient_id) then return null; end if;
  if p_kind='rule' then
    select jsonb_build_object(
      'rule_id',r.id,'rule_updated_at',r.updated_at,'definition_id',d.id,'definition_updated_at',d.updated_at,'title',d.title,'category',d.category,
      'phase',d.routine_phase,'completion_mode',d.completion_mode,'definition_active',d.is_active,
      'weekday',r.weekday,'slot_key',r.slot_key,'strategy',r.assignee_strategy,
      'assignee_id',r.planned_assignee_id,'fallback_assignee_id',r.fallback_assignee_id,
      'scheduled_local_time',r.scheduled_local_time,'effective_from',r.effective_from,
      'effective_to',r.effective_to,'active',r.active,'version',r.version,'created_by',r.created_by,
      'transport_template_id',r.transport_template_id,'transport_leg',r.transport_leg,
      'subtasks',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'title',s.title,
        'required',s.required,'sort_order',s.sort_order) order by s.sort_order,s.id)
        from public.task_subtask_definitions s where s.household_id=d.household_id and s.task_definition_id=d.id and s.is_active),'[]'::jsonb))
    into result
    from public.recurrence_rules r join public.task_definitions d on d.household_id=r.household_id and d.id=r.task_definition_id
    where r.household_id=p_household_id and r.id=p_target_id and r.active and d.is_active
      and (r.effective_to is null or r.effective_to>=today)
      -- Template-backed transport is agreed separately as a weekly plan.
      and r.transport_template_id is null
      and ((r.assignee_strategy='fixed' and r.planned_assignee_id=p_recipient_id)
        or (r.assignee_strategy not in ('fixed','unassigned','anyone_adult') and exists(
          select 1 from public.task_instances t where t.household_id=r.household_id and t.recurrence_rule_id=r.id
            and t.planned_assignee_id=p_recipient_id and t.test_context_id is null
            and t.scheduled_date between today and today+28)));
  elsif p_kind='transport' then
    select jsonb_build_object('template_id',t.id,'revision',t.revision,'valid_from',t.valid_from,
      'valid_to',t.valid_to,'created_by',t.created_by,
      'days',coalesce((select jsonb_agg(jsonb_build_object('weekday',x.weekday,
        'dropoff',x.dropoff_user_id=p_recipient_id,'pickup',x.pickup_user_id=p_recipient_id,
        'dropoff_time',case when x.dropoff_user_id=p_recipient_id then x.dropoff_local_time else null end,
        'pickup_time',case when x.pickup_user_id=p_recipient_id then x.pickup_local_time else null end)
        order by x.weekday) from public.transport_weekly_template_days x
        where x.household_id=t.household_id and x.template_id=t.id
          and (x.dropoff_user_id=p_recipient_id or x.pickup_user_id=p_recipient_id)),'[]'::jsonb))
    into result from public.transport_weekly_templates t
    where t.household_id=p_household_id and t.id=p_target_id and (t.valid_to is null or t.valid_to>=today)
      and exists(select 1 from public.transport_weekly_template_days x where x.household_id=t.household_id
        and x.template_id=t.id and (x.dropoff_user_id=p_recipient_id or x.pickup_user_id=p_recipient_id));
  end if;
  return result;
end $$;
revoke all on function private.fn_assignment_consent_snapshot_v1(uuid,uuid,text,uuid) from public,anon,authenticated,service_role;

-- The check is fail-closed, including for historical self-assignments:
-- created_by can describe an old creator rather than the latest editor. A
-- later writer integration can record a self-assignment at the point where
-- it can prove who set the exact rule. Do not infer that from legacy rows.
create function private.fn_has_assignment_consent_v1(
  p_household_id uuid,p_recipient_id uuid,p_kind text,p_target_id uuid
) returns boolean language plpgsql stable security definer set search_path='' as $$
declare v_snapshot jsonb;
begin
  v_snapshot:=private.fn_assignment_consent_snapshot_v1(p_household_id,p_recipient_id,p_kind,p_target_id);
  if v_snapshot is null then return false; end if;
  return exists(select 1 from private.assignment_consents c where c.household_id=p_household_id
    and c.recipient_id=p_recipient_id and c.kind=p_kind and c.target_id=p_target_id and c.snapshot=v_snapshot);
end $$;
revoke all on function private.fn_has_assignment_consent_v1(uuid,uuid,text,uuid) from public,anon,authenticated,service_role;

-- Internal preparation; not yet connected to the weekly LINE scheduler.
-- The recipient's membership row serializes duplicate preparations.
create function public.server_tx_prepare_assignment_consent_v1(p_actor_id uuid,p_kind text,p_target_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb; hh uuid; v_snapshot jsonb; offer private.assignment_consent_offers%rowtype;
begin
  if p_actor_id is null or p_target_id is null or p_kind is null or p_kind not in ('rule','transport') then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id); hh:=(ctx->>'household_id')::uuid;
  perform 1 from public.household_members where household_id=hh and user_id=p_actor_id for update;
  v_snapshot:=private.fn_assignment_consent_snapshot_v1(hh,p_actor_id,p_kind,p_target_id);
  if v_snapshot is null then return jsonb_build_object('ok',false,'unavailable',true); end if;
  if private.fn_has_assignment_consent_v1(hh,p_actor_id,p_kind,p_target_id) then
    return jsonb_build_object('ok',false,'already_agreed',true);
  end if;
  select * into offer from private.assignment_consent_offers o where o.household_id=hh and o.recipient_id=p_actor_id
    and o.kind=p_kind and o.target_id=p_target_id and o.snapshot=v_snapshot and o.status='pending'
    order by o.created_at desc limit 1;
  if not found then
    insert into private.assignment_consent_offers(household_id,recipient_id,kind,target_id,snapshot)
    values(hh,p_actor_id,p_kind,p_target_id,v_snapshot) returning * into offer;
  end if;
  return jsonb_build_object('ok',true,'offer_id',offer.id,'kind',p_kind,'snapshot',v_snapshot);
end $$;
revoke all on function public.server_tx_prepare_assignment_consent_v1(uuid,text,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_prepare_assignment_consent_v1(uuid,text,uuid) to service_role;

-- Only the addressed recipient can accept, and only the exact offer seen.
-- Replays are idempotent and changing the underlying rule invalidates the
-- acceptance on the next check even if a writer reuses a numeric version.
create function public.server_tx_accept_assignment_consent_v1(p_actor_id uuid,p_offer_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb; hh uuid; offer private.assignment_consent_offers%rowtype; v_snapshot jsonb; definition_id uuid;
begin
  if p_actor_id is null or p_offer_id is null then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id); hh:=(ctx->>'household_id')::uuid;
  select * into offer from private.assignment_consent_offers where id=p_offer_id and household_id=hh and recipient_id=p_actor_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if offer.status='agreed' then
    if private.fn_has_assignment_consent_v1(hh,p_actor_id,offer.kind,offer.target_id) then
      return jsonb_build_object('ok',true,'already_agreed',true);
    end if;
    return jsonb_build_object('ok',false,'stale',true);
  end if;
  if offer.status<>'pending' then return jsonb_build_object('ok',false,'closed',true); end if;
  if offer.kind='rule' then
    select task_definition_id into definition_id from public.recurrence_rules where household_id=hh and id=offer.target_id;
    perform 1 from public.task_definitions where household_id=hh and id=definition_id for no key update;
    perform 1 from public.recurrence_rules where household_id=hh and id=offer.target_id for no key update;
  else
    perform 1 from public.transport_weekly_templates where household_id=hh and id=offer.target_id for no key update;
  end if;
  v_snapshot:=private.fn_assignment_consent_snapshot_v1(hh,p_actor_id,offer.kind,offer.target_id);
  if v_snapshot is distinct from offer.snapshot then return jsonb_build_object('ok',false,'stale',true); end if;
  insert into private.assignment_consents(household_id,recipient_id,kind,target_id,snapshot,offer_id)
  values(hh,p_actor_id,offer.kind,offer.target_id,offer.snapshot,offer.id)
  on conflict(household_id,recipient_id,kind,target_id) do update
    set snapshot=excluded.snapshot,offer_id=excluded.offer_id,agreed_at=now();
  update private.assignment_consent_offers set status='agreed',responded_at=now() where id=offer.id;
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.server_tx_accept_assignment_consent_v1(uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_accept_assignment_consent_v1(uuid,uuid) to service_role;

-- A request to discuss is a direct, optional family message and respects the
-- same recipient preference as existing requests. Preserve all existing maps.
alter function private.fn_line_preference_column_for_type(text) rename to fn_line_preference_before_assignment_consent_v1;
create function private.fn_line_preference_column_for_type(p_type text)
returns text language sql immutable security invoker set search_path='' as $$
  select case when p_type='assignment.consent_change_requested' then 'request_line'
    else private.fn_line_preference_before_assignment_consent_v1(p_type) end;
$$;
revoke all on function private.fn_line_preference_column_for_type(text) from public,anon,authenticated;
grant execute on function private.fn_line_preference_column_for_type(text) to service_role;

-- No assignment or existing task is mutated by either answer. A change
-- request creates at most one notification and never asks for a reason.
create function public.server_tx_defer_assignment_consent_v1(p_actor_id uuid,p_offer_id uuid,p_action text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  ctx jsonb; hh uuid; actor_ref uuid; offer private.assignment_consent_offers%rowtype;
  definition_id uuid; snapshot jsonb; target uuid; target_ref uuid; target_count integer; body text; outcome text;
begin
  if p_actor_id is null or p_offer_id is null or p_action is null or p_action not in ('change','later') then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id); hh:=(ctx->>'household_id')::uuid; actor_ref:=(ctx->>'actor_ref_id')::uuid;
  select * into offer from private.assignment_consent_offers where id=p_offer_id and household_id=hh and recipient_id=p_actor_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  outcome:=case when p_action='change' then 'change_requested' else 'later' end;
  if offer.status=outcome then return jsonb_build_object('ok',true,'already_answered',true); end if;
  if offer.status<>'pending' then return jsonb_build_object('ok',false,'closed',true); end if;
  if offer.kind='rule' then
    select task_definition_id into definition_id from public.recurrence_rules where household_id=hh and id=offer.target_id;
    perform 1 from public.task_definitions where household_id=hh and id=definition_id for no key update;
    perform 1 from public.recurrence_rules where household_id=hh and id=offer.target_id for no key update;
  else
    perform 1 from public.transport_weekly_templates where household_id=hh and id=offer.target_id for no key update;
  end if;
  snapshot:=private.fn_assignment_consent_snapshot_v1(hh,p_actor_id,offer.kind,offer.target_id);
  if snapshot is distinct from offer.snapshot then return jsonb_build_object('ok',false,'stale',true); end if;
  if p_action='change' then
    -- Historical created_by is not reliable evidence of the latest editor.
    -- In a two-adult household the other adult is the consultation partner;
    -- with more possible recipients, fail closed rather than guessing.
    select count(*),min(user_id::text)::uuid into target_count,target from public.household_members
      where household_id=hh and user_id<>p_actor_id and member_role='adult';
    if target_count<>1 then return jsonb_build_object('ok',false,'unavailable',true); end if;
    select id into target_ref from public.domain_actor_refs where household_id=hh and real_user_id=target and actor_kind='real_user' and test_context_id is null;
    if target_ref is null then return jsonb_build_object('ok',false,'unavailable',true); end if;
    body:='「'||case when offer.kind='transport' then '送り迎え' else left(snapshot->>'title',100) end||'」の担当を相談したいそうです。';
    perform private.fn_emit_notification_intent_v1(hh,p_actor_id,actor_ref,null,target_ref,
      'assignment.consent_change_requested',body,body,jsonb_build_object('offer_id',offer.id),
      'assignment-consent-change:'||offer.id::text,'immediate','normal',null,null,'assignment_consent_offer',offer.id,null);
  end if;
  update private.assignment_consent_offers set status=outcome,responded_at=now() where id=offer.id;
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.server_tx_defer_assignment_consent_v1(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.server_tx_defer_assignment_consent_v1(uuid,uuid,text) to service_role;

-- Future notification and bulk-action integrations share this predicate.
-- It is intentionally not wired in this foundation: individual accepted
-- assignment changes and transport-dependent duties need end-to-end tests
-- before any existing family notifications are suppressed.
create function private.fn_task_assignment_consent_v1(p_household_id uuid,p_recipient_id uuid,p_task_id uuid)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare task public.task_instances%rowtype; rule public.recurrence_rules%rowtype; ref uuid;
begin
  if p_household_id is null or p_recipient_id is null or p_task_id is null then return false; end if;
  select id into ref from public.domain_actor_refs where household_id=p_household_id and real_user_id=p_recipient_id
    and actor_kind='real_user' and test_context_id is null;
  if ref is null then return false; end if;
  select * into task from public.task_instances where household_id=p_household_id and id=p_task_id and test_context_id is null;
  if not found then return false; end if;
  -- Claiming shared work is a direct choice by this person. Never treat
  -- someone else's claim as their agreement.
  if task.assignment_mode='anyone' then return coalesce(task.active_claimant_actor_ref_id=ref,false); end if;
  if task.planned_assignee_id is distinct from p_recipient_id then return false; end if;
  -- An accepted one-off handoff is independent of a standing rule.
  if task.assignment_source='agreement' then return true; end if;
  if task.recurrence_rule_id is null then return true; end if;
  select * into rule from public.recurrence_rules where household_id=p_household_id and id=task.recurrence_rule_id;
  if not found then return false; end if;
  if rule.transport_template_id is not null then
    return private.fn_has_assignment_consent_v1(p_household_id,p_recipient_id,'transport',rule.transport_template_id);
  end if;
  return private.fn_has_assignment_consent_v1(p_household_id,p_recipient_id,'rule',rule.id);
end $$;
revoke all on function private.fn_task_assignment_consent_v1(uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function private.fn_task_assignment_consent_v1(uuid,uuid,uuid) to service_role;

-- A recipient sees at most three proposals per local week, even when a push
-- is retried or two workers race. The notification identity binds the
-- proposals to the actual Sunday morning note, not a caller-supplied list.
create table private.assignment_consent_weekly_briefs (
  household_id uuid not null,
  recipient_id uuid not null,
  week_start date not null,
  notification_id uuid not null references public.user_notifications(id) on delete cascade,
  offer_ids uuid[] not null default '{}'::uuid[] check(cardinality(offer_ids)<=3),
  created_at timestamptz not null default now(),
  primary key(household_id,recipient_id,week_start),
  unique(notification_id),
  foreign key(household_id,recipient_id) references public.household_members(household_id,user_id) on delete cascade
);
alter table private.assignment_consent_weekly_briefs enable row level security;
revoke all on private.assignment_consent_weekly_briefs from public,anon,authenticated;

create function public.server_tx_prepare_weekly_assignment_consent_v1(
  p_actor_id uuid,p_notification_id uuid,p_now timestamptz default now()
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  ctx jsonb; hh uuid; n public.user_notifications%rowtype; day_jst date; v_week_start date; stored private.assignment_consent_weekly_briefs%rowtype;
  candidate record; prepared jsonb; ids uuid[]:='{}'::uuid[]; offer uuid; result jsonb;
begin
  if p_actor_id is null or p_notification_id is null or p_now is null then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id); hh:=(ctx->>'household_id')::uuid;
  day_jst:=(p_now at time zone 'Asia/Tokyo')::date;
  if extract(isodow from day_jst)<>7 then return '[]'::jsonb; end if;
  select * into n from public.user_notifications where id=p_notification_id and household_id=hh and recipient_user_id=p_actor_id
    and test_context_id is null and type='daily_brief.v2' and title='朝のおうちノート';
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if n.payload#>>'{brief,local_date}' is distinct from day_jst::text or char_length(n.body)>=5000 then return '[]'::jsonb; end if;
  v_week_start:=day_jst-6;
  perform 1 from public.household_members where household_id=hh and user_id=p_actor_id for update;
  select * into stored from private.assignment_consent_weekly_briefs w
    where w.household_id=hh and w.recipient_id=p_actor_id and w.week_start=v_week_start;
  if found then
    -- A different notification cannot cause a second round that week.
    if stored.notification_id<>p_notification_id then return '[]'::jsonb; end if;
    ids:=stored.offer_ids;
  else
    for candidate in
      select x.kind,x.target_id from (
        select 'transport'::text kind,t.id target_id,0 priority,t.valid_from::text order_key
        from public.transport_weekly_templates t
        where t.household_id=hh and (t.valid_to is null or t.valid_to>=day_jst)
          and t.valid_from<=day_jst+28
          and private.fn_assignment_consent_snapshot_v1(hh,p_actor_id,'transport',t.id) is not null
          and not private.fn_has_assignment_consent_v1(hh,p_actor_id,'transport',t.id)
        union all
        select q.kind,q.target_id,q.priority,q.order_key from (
          -- Different weekdays of the same chore are proposed in different
          -- weeks, so a 3-card bundle never repeats the same chore.
          select distinct on (r.task_definition_id) 'rule'::text kind,r.id target_id,1 priority,
            d.title||':'||r.weekday::text||':'||r.id::text order_key
          from public.recurrence_rules r join public.task_definitions d on d.household_id=r.household_id and d.id=r.task_definition_id
          where r.household_id=hh and r.active and r.transport_template_id is null
            and r.effective_from<=day_jst+28 and (r.effective_to is null or r.effective_to>=day_jst)
            and r.assignee_strategy in ('fixed','dropoff_assignee','pickup_assignee','nonpickup_adult',
              'next_day_nondropoff_adult','previous_evening_assignee')
            -- The LINE proposal must show all of the work being agreed to.
            and char_length(d.title)<=120
            and (select count(*) from public.task_subtask_definitions s where s.household_id=hh and s.task_definition_id=d.id and s.is_active)<=8
            and not exists(select 1 from public.task_subtask_definitions s where s.household_id=hh
              and s.task_definition_id=d.id and s.is_active and char_length(s.title)>120)
            and private.fn_assignment_consent_snapshot_v1(hh,p_actor_id,'rule',r.id) is not null
            and not private.fn_has_assignment_consent_v1(hh,p_actor_id,'rule',r.id)
          order by r.task_definition_id,r.weekday,r.id
        ) q
      ) x order by x.priority,x.order_key,x.target_id
    loop
      prepared:=public.server_tx_prepare_assignment_consent_v1(p_actor_id,candidate.kind,candidate.target_id);
      if prepared->>'ok'='true' then
        offer:=(prepared->>'offer_id')::uuid;
        ids:=array_append(ids,offer);
        exit when cardinality(ids)>=3;
      end if;
    end loop;
    insert into private.assignment_consent_weekly_briefs(household_id,recipient_id,week_start,notification_id,offer_ids)
      values(hh,p_actor_id,v_week_start,p_notification_id,ids);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('offer_id',o.id,'kind',o.kind,'snapshot',o.snapshot) order by x.ord),'[]'::jsonb)
    into result from unnest(ids) with ordinality x(id,ord)
    join private.assignment_consent_offers o on o.id=x.id and o.household_id=hh and o.recipient_id=p_actor_id
    where o.status='pending' and o.snapshot=private.fn_assignment_consent_snapshot_v1(hh,p_actor_id,o.kind,o.target_id);
  return result;
end $$;
revoke all on function public.server_tx_prepare_weekly_assignment_consent_v1(uuid,uuid,timestamptz) from public,anon,authenticated;
grant execute on function public.server_tx_prepare_weekly_assignment_consent_v1(uuid,uuid,timestamptz) to service_role;

-- Hide only the recipient's unagreed recurring assignments in scheduled
-- LINE briefs. Remove every reference to the task, including when the brief
-- places it in a special, waiting or carryover section, before summarization.
create function private.fn_filter_unagreed_line_brief_v1(p_value jsonb,p_household uuid,p_recipient uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; k text; v jsonb; child jsonb; task_id uuid;
begin
  if p_value is null then return null; end if;
  if jsonb_typeof(p_value)='object' then
    if coalesce(p_value->>'task_id','') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      task_id:=(p_value->>'task_id')::uuid;
      if exists(select 1 from public.task_instances t where t.household_id=p_household and t.id=task_id
        and t.test_context_id is null and t.recurrence_rule_id is not null and t.planned_assignee_id=p_recipient
        and not private.fn_task_assignment_consent_v1(p_household,p_recipient,t.id)) then return null; end if;
    end if;
    result:='{}'::jsonb;
    for k,v in select key,value from jsonb_each(p_value) loop
      child:=private.fn_filter_unagreed_line_brief_v1(v,p_household,p_recipient);
      if child is not null then result:=result||jsonb_build_object(k,child); end if;
    end loop;
    return result;
  elsif jsonb_typeof(p_value)='array' then
    result:='[]'::jsonb;
    for v in select value from jsonb_array_elements(p_value) with ordinality as x(value,ord) order by ord loop
      child:=private.fn_filter_unagreed_line_brief_v1(v,p_household,p_recipient);
      if child is not null then result:=result||jsonb_build_array(child); end if;
    end loop;
    return result;
  end if;
  return p_value;
end $$;
revoke all on function private.fn_filter_unagreed_line_brief_v1(jsonb,uuid,uuid) from public,anon,authenticated,service_role;

alter function private.fn_daily_brief_for_line_v1(jsonb,uuid,timestamptz,text) rename to fn_daily_brief_before_consent_v1;
create function private.fn_daily_brief_for_line_v1(p_brief jsonb,p_recipient uuid,p_at timestamptz,p_mode text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare hh uuid;
begin
  select household_id into hh from public.household_members where user_id=p_recipient;
  if hh is null then return '{}'::jsonb; end if;
  return private.fn_daily_brief_before_consent_v1(
    private.fn_filter_unagreed_line_brief_v1(p_brief,hh,p_recipient),p_recipient,p_at,p_mode);
end $$;
revoke all on function private.fn_daily_brief_for_line_v1(jsonb,uuid,timestamptz,text) from public,anon,authenticated;
grant execute on function private.fn_daily_brief_for_line_v1(jsonb,uuid,timestamptz,text) to service_role;

-- Previously prepared batches may exist when consent is first enabled.
-- Filter preparation and revalidate at tap time, so an old LINE button can
-- never record a newly tentative assignment.
alter function public.server_tx_prepare_line_bulk_v1(uuid,uuid) rename to server_tx_prepare_line_bulk_before_consent_v1;
revoke all on function public.server_tx_prepare_line_bulk_before_consent_v1(uuid,uuid) from public,anon,authenticated,service_role;
create function public.server_tx_prepare_line_bulk_v1(p_actor_id uuid,p_notification_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb; hh uuid; prepared jsonb; batch private.line_bulk_batches%rowtype; allowed jsonb;
begin
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id); hh:=(ctx->>'household_id')::uuid;
  prepared:=public.server_tx_prepare_line_bulk_before_consent_v1(p_actor_id,p_notification_id);
  if prepared is null or prepared->>'id' is null then return null; end if;
  select * into batch from private.line_bulk_batches where id=(prepared->>'id')::uuid and household_id=hh and actor_id=p_actor_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if batch.status<>'ready' then return prepared; end if;
  select coalesce(jsonb_agg(x.item order by x.ord),'[]'::jsonb) into allowed
  from jsonb_array_elements(batch.items) with ordinality x(item,ord)
  where private.fn_task_assignment_consent_v1(hh,p_actor_id,(x.item->>'id')::uuid);
  update private.line_bulk_batches set items=allowed where id=batch.id;
  if jsonb_array_length(allowed)=0 then return null; end if;
  return prepared;
end $$;
revoke all on function public.server_tx_prepare_line_bulk_v1(uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_prepare_line_bulk_v1(uuid,uuid) to service_role;

alter function public.server_tx_complete_line_bulk_v1(uuid,uuid) rename to server_tx_complete_line_bulk_before_consent_v1;
revoke all on function public.server_tx_complete_line_bulk_before_consent_v1(uuid,uuid) from public,anon,authenticated,service_role;
create function public.server_tx_complete_line_bulk_v1(p_actor_id uuid,p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb; hh uuid; batch private.line_bulk_batches%rowtype;
begin
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id); hh:=(ctx->>'household_id')::uuid;
  select * into batch from private.line_bulk_batches where id=p_batch_id and household_id=hh and actor_id=p_actor_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if batch.status='ready' and (jsonb_array_length(batch.items)=0 or exists(
    select 1 from jsonb_array_elements(batch.items) x where not private.fn_task_assignment_consent_v1(hh,p_actor_id,(x->>'id')::uuid)
  )) then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  return public.server_tx_complete_line_bulk_before_consent_v1(p_actor_id,p_batch_id);
end $$;
revoke all on function public.server_tx_complete_line_bulk_v1(uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_complete_line_bulk_v1(uuid,uuid) to service_role;


-- The morning nudge also respects the same rule; unclaimed shared work is
-- still available because no person has been assigned it.
create or replace function public.server_tx_dispatch_morning_nudges(p_now timestamptz default now())
returns integer language plpgsql security invoker set search_path = '' as $$
declare
  v_local timestamp := p_now at time zone 'Asia/Tokyo';
  v_date date := (p_now at time zone 'Asia/Tokyo')::date;
  v_noon timestamptz := ((v_date + time '12:00') at time zone 'Asia/Tokyo');
  h record; m record; v_items jsonb; v_part text; v_message text; v_header text; v_key text; v_note uuid; v_sent integer := 0;
begin
  if private.is_jp_nonworkday(v_date) then return 0; end if;
  for h in
    select id, morning_nudge_local_time as nudge_at from public.households
    where morning_nudge_local_time is not null
      and v_local >= (v_date + morning_nudge_local_time)
      and v_local < (v_date + morning_nudge_local_time) + interval '45 minutes'
  loop
    for m in select user_id from public.household_members where household_id = h.id loop
      -- This person's open morning work: their own, shared ones nobody has taken, and ones they took.
      select coalesce(jsonb_agg(jsonb_build_object('task_id', t.id, 'title', t.title)
          order by t.due_at nulls last, t.title, t.id), '[]'::jsonb)
      into v_items
      from public.task_instances t
      left join public.task_definitions d on d.household_id = t.household_id and d.id = t.task_definition_id
      left join public.domain_actor_refs ar on ar.household_id = t.household_id
        and ar.id = t.active_claimant_actor_ref_id and ar.actor_kind = 'real_user' and ar.test_context_id is null
      where t.household_id = h.id and t.scheduled_date = v_date and t.test_context_id is null
        and t.status in ('todo', 'in_progress')
        and coalesce(t.expectation, 'normal') <> 'optional'
        and (t.routine_phase = 'morning' or t.due_at < v_noon)
        and coalesce(d.code, '') not like 'codmon%'
        and (t.planned_assignee_id = m.user_id or t.assignment_mode = 'anyone')
        and (ar.real_user_id is null or ar.real_user_id = m.user_id)
        and ((t.assignment_mode='anyone' and ar.real_user_id is null)
          or private.fn_task_assignment_consent_v1(h.id,m.user_id,t.id));
      continue when jsonb_array_length(v_items) = 0;
      v_part := private.fn_line_task_timeline_v1(private.fn_task_display_items_v1(h.id, v_items), m.user_id::text);
      continue when v_part is null;
      v_header := '⏰ 朝の残り（' || to_char(v_local, 'HH24:MI') || '）';
      v_message := v_header || E'\n' || v_part;  -- opens with the LINE item title, so it is shown once
      v_key := 'morning-nudge:' || v_date::text || ':' || m.user_id::text;
      v_note := null;
      insert into public.user_notifications(household_id, recipient_user_id, type, title, body, payload, dedup_key)
      values (h.id, m.user_id, 'morning_nudge', '朝の残り', v_message,
        jsonb_build_object('date', v_date, 'task_count', jsonb_array_length(v_items)), v_key)
      on conflict do nothing returning id into v_note;
      continue when v_note is null;
      perform public.server_tx_enqueue_web_push(h.id, m.user_id, '朝の残り', v_part, '/', 'morning-nudge', v_key, v_noon);
      if exists (select 1 from public.notification_preferences
        where household_id = h.id and user_id = m.user_id and daily_assignment_line) then
        insert into private.notification_outbox(household_id, recipient_user_id, channel, type, payload, dedup_key, priority, business_expires_at)
        values (h.id, m.user_id, 'line', 'morning_nudge',
          jsonb_build_object('items', jsonb_build_array(jsonb_build_object('title', v_header, 'body', v_message))),
          v_key, 'reminder', p_now + interval '90 minutes') on conflict do nothing;
      end if;
      v_sent := v_sent + 1;
    end loop;
  end loop;
  return v_sent;
end $$;

-- Record a self-assignment only at the command boundary that proves the
-- caller just chose these exact contents. Historical created_by is not proof.
create function private.fn_record_self_assignment_consent_v1(p_actor uuid,p_kind text,p_target uuid)
returns void language plpgsql security definer set search_path='' as $$
declare proposal jsonb; accepted jsonb;
begin
  proposal:=public.server_tx_prepare_assignment_consent_v1(p_actor,p_kind,p_target);
  if proposal->>'ok'='true' then
    accepted:=public.server_tx_accept_assignment_consent_v1(p_actor,(proposal->>'offer_id')::uuid);
    if accepted->>'ok' is distinct from 'true' then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  end if;
end $$;
revoke all on function private.fn_record_self_assignment_consent_v1(uuid,text,uuid) from public,anon,authenticated,service_role;

alter function public.server_tx_change_recurrence(uuid,uuid,uuid,int,text,text,uuid,time,int,date) rename to server_tx_change_recurrence_before_consent_v1;
revoke all on function public.server_tx_change_recurrence_before_consent_v1(uuid,uuid,uuid,int,text,text,uuid,time,int,date) from public,anon,authenticated,service_role;
create function public.server_tx_change_recurrence(
  p_actor_id uuid,p_operation_id uuid,p_task_definition_id uuid,p_weekday int,p_slot_key text,
  p_assignee_strategy text,p_planned_assignee_user_id uuid,p_scheduled_local_time time,
  p_conflict_window_minutes int,p_effective_from date
) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; replay boolean;
begin
  if p_actor_id is null or p_operation_id is null then raise exception 'INVALID_INPUT'; end if;
  perform private.fn_require_production_actor_context_v1(p_actor_id);
  -- Serialize the preflight and command, so an idempotent retry cannot accept
  -- a rule that somebody edited after the original successful operation.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('self-consent:recurrence:'||p_actor_id::text||':'||p_operation_id::text,0));
  select exists(select 1 from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id) into replay;
  result:=public.server_tx_change_recurrence_before_consent_v1(p_actor_id,p_operation_id,p_task_definition_id,p_weekday,p_slot_key,
    p_assignee_strategy,p_planned_assignee_user_id,p_scheduled_local_time,p_conflict_window_minutes,p_effective_from);
  if not replay and p_assignee_strategy='fixed' and p_planned_assignee_user_id=p_actor_id and result->>'rule_id' is not null then
    perform private.fn_record_self_assignment_consent_v1(p_actor_id,'rule',(result->>'rule_id')::uuid);
  end if;
  return result;
end $$;
revoke all on function public.server_tx_change_recurrence(uuid,uuid,uuid,int,text,text,uuid,time,int,date) from public,anon,authenticated;
grant execute on function public.server_tx_change_recurrence(uuid,uuid,uuid,int,text,text,uuid,time,int,date) to service_role;

alter function public.server_tx_save_transport_template_v2(uuid,uuid,date,jsonb) rename to server_tx_save_transport_template_before_consent_v1;
revoke all on function public.server_tx_save_transport_template_before_consent_v1(uuid,uuid,date,jsonb) from public,anon,authenticated,service_role;
create function public.server_tx_save_transport_template_v2(p_actor_id uuid,p_operation_id uuid,p_valid_from date,p_days jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb; actor_ref uuid; result jsonb; replay boolean;
begin
  if p_actor_id is null or p_operation_id is null then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id); actor_ref:=(ctx->>'actor_ref_id')::uuid;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('self-consent:transport:'||p_actor_id::text||':'||p_operation_id::text,0));
  select exists(select 1 from private.canonical_operation_receipts where actor_ref_id=actor_ref and operation_id=p_operation_id and test_context_id is null) into replay;
  result:=public.server_tx_save_transport_template_before_consent_v1(p_actor_id,p_operation_id,p_valid_from,p_days);
  if not replay and result->>'template_id' is not null then
    perform private.fn_record_self_assignment_consent_v1(p_actor_id,'transport',(result->>'template_id')::uuid);
  end if;
  return result;
end $$;
revoke all on function public.server_tx_save_transport_template_v2(uuid,uuid,date,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_save_transport_template_v2(uuid,uuid,date,jsonb) to service_role;

-- Yesterday's former generic "all done" button must also honor agreement.
-- Bind its exact eligible work to the actual morning note and revalidate the
-- entire set under lock; no newly added or tentative item can be closed.
create table private.previous_day_consent_batches (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null,
  actor_id uuid not null,
  notification_id uuid not null unique references public.user_notifications(id) on delete cascade,
  local_date date not null,
  items jsonb not null check(jsonb_typeof(items)='array'),
  completed_items jsonb,
  status text not null default 'ready' check(status in ('ready','completed','undone')),
  completed_at timestamptz,
  foreign key(household_id,actor_id) references public.household_members(household_id,user_id) on delete cascade
);
alter table private.previous_day_consent_batches enable row level security;
revoke all on private.previous_day_consent_batches from public,anon,authenticated;

create function public.server_tx_prepare_previous_day_consent_v1(p_actor_id uuid,p_notification_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb; hh uuid; today date:=(now() at time zone 'Asia/Tokyo')::date; n public.user_notifications%rowtype;
  b private.previous_day_consent_batches%rowtype; items jsonb; bid uuid;
begin
  if p_actor_id is null or p_notification_id is null then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id); hh:=(ctx->>'household_id')::uuid;
  select * into n from public.user_notifications where id=p_notification_id and household_id=hh and recipient_user_id=p_actor_id
    and type='daily_brief.v2' and title='朝のおうちノート' and test_context_id is null;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if n.payload#>>'{brief,local_date}' is distinct from today::text then return null; end if;
  select * into b from private.previous_day_consent_batches where notification_id=p_notification_id;
  if found then return jsonb_build_object('id',b.id,'date',b.local_date,'status',b.status); end if;
  if not exists(select 1 from public.task_events e where e.household_id=hh and e.actor_id=p_actor_id and e.test_context_id is null
    and e.created_at>=now()-interval '7 days' and e.event_type in ('completed','skipped','subtask_completed','work_progress_recorded')) then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'revision',t.revision) order by t.id),'[]'::jsonb) into items
  from public.task_instances t left join public.task_definitions d on d.household_id=t.household_id and d.id=t.task_definition_id
  where t.household_id=hh and t.test_context_id is null and t.scheduled_date=today-1 and t.planned_assignee_id=p_actor_id
    and t.status in ('todo','in_progress') and coalesce(t.expectation,'normal')<>'optional'
    and coalesce(d.code,'')<>'codmon_submit' and private.fn_task_assignment_consent_v1(hh,p_actor_id,t.id);
  if jsonb_array_length(items)=0 or jsonb_array_length(items)>80 then return null; end if;
  insert into private.previous_day_consent_batches(household_id,actor_id,notification_id,local_date,items)
    values(hh,p_actor_id,p_notification_id,today-1,items) on conflict(notification_id) do nothing returning id into bid;
  if bid is null then select id into bid from private.previous_day_consent_batches where notification_id=p_notification_id and actor_id=p_actor_id; end if;
  return jsonb_build_object('id',bid,'date',today-1,'status','ready');
end $$;
revoke all on function public.server_tx_prepare_previous_day_consent_v1(uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_prepare_previous_day_consent_v1(uuid,uuid) to service_role;

create function public.server_tx_complete_previous_day_consent_v1(p_actor_id uuid,p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb; hh uuid; b private.previous_day_consent_batches%rowtype; x jsonb; task public.task_instances%rowtype; r jsonb; done jsonb:='[]'::jsonb;
begin
  if p_actor_id is null or p_batch_id is null then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id); hh:=(ctx->>'household_id')::uuid;
  select * into b from private.previous_day_consent_batches where id=p_batch_id and household_id=hh and actor_id=p_actor_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if b.status='completed' then return jsonb_build_object('ok',true,'already_completed',true); end if;
  if b.status='undone' then return jsonb_build_object('ok',false,'already_undone',true); end if;
  if b.local_date<>(now() at time zone 'Asia/Tokyo')::date-1 then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  for x in select value from jsonb_array_elements(b.items) order by value->>'id' loop
    select * into task from public.task_instances where household_id=hh and id=(x->>'id')::uuid and test_context_id is null for update;
    if not found or task.revision<>(x->>'revision')::bigint or task.scheduled_date<>b.local_date
      or task.planned_assignee_id is distinct from p_actor_id or task.status not in ('todo','in_progress')
      or coalesce(task.expectation,'normal')='optional' or not private.fn_task_assignment_consent_v1(hh,p_actor_id,task.id) then
      raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  end loop;
  for x in select value from jsonb_array_elements(b.items) order by value->>'id' loop
    r:=private.fn_line_bulk_complete_one_v1(p_actor_id,pg_catalog.md5(b.id::text||':previous-complete:'||(x->>'id'))::uuid,(x->>'id')::uuid);
    done:=done||jsonb_build_array(jsonb_build_object('id',x->>'id','revision',(r->>'revision')::bigint));
  end loop;
  update private.previous_day_consent_batches set status='completed',completed_items=done,completed_at=now() where id=b.id;
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.server_tx_complete_previous_day_consent_v1(uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_complete_previous_day_consent_v1(uuid,uuid) to service_role;

create function public.server_tx_undo_previous_day_consent_v1(p_actor_id uuid,p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb; hh uuid; b private.previous_day_consent_batches%rowtype; x jsonb; task public.task_instances%rowtype;
begin
  if p_actor_id is null or p_batch_id is null then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id); hh:=(ctx->>'household_id')::uuid;
  select * into b from private.previous_day_consent_batches where id=p_batch_id and household_id=hh and actor_id=p_actor_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if b.status='undone' then return jsonb_build_object('ok',true,'already_undone',true); end if;
  if b.status<>'completed' or b.completed_at is null or b.completed_at<now()-interval '24 hours' then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  for x in select value from jsonb_array_elements(b.completed_items) order by value->>'id' loop
    select * into task from public.task_instances where household_id=hh and id=(x->>'id')::uuid and test_context_id is null for update;
    if not found or task.revision<>(x->>'revision')::bigint or task.status<>'completed' then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  end loop;
  for x in select value from jsonb_array_elements(b.completed_items) order by value->>'id' loop
    perform public.server_tx_reopen_task_with_checklist_undo_v1(p_actor_id,pg_catalog.md5(b.id::text||':previous-undo:'||(x->>'id'))::uuid,
      (x->>'id')::uuid,(x->>'revision')::bigint,'line');
  end loop;
  update private.previous_day_consent_batches set status='undone' where id=b.id;
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.server_tx_undo_previous_day_consent_v1(uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_undo_previous_day_consent_v1(uuid,uuid) to service_role;


-- The Sunday preview used to be household-wide and could reveal a tentative
-- transport assignment even after the daily task list was filtered. Render it
-- for the recipient, without altering calendars or individually agreed rides.
create function private.fn_render_weekly_preview_for_recipient_v1(
  p_household_id uuid,
  p_monday date,
  p_recipient uuid
) returns text
language plpgsql stable security invoker set search_path = ''
as $$
declare
  v_day date;
  v_dropoff text;
  v_pickup text;
  v_special text;
  v_cal text;
  v_hl text;
  v_block text;
  v_out text := '';
begin
  for v_day in select d::date from generate_series(p_monday, p_monday + 6, interval '1 day') d loop
    select case when ti.planned_assignee_id=p_recipient and ti.recurrence_rule_id is not null
      and not private.fn_task_assignment_consent_v1(p_household_id,p_recipient,ti.id) then '相談中'
      else regexp_replace(coalesce(p.display_name,'未定'), '（仮）$', '') end into v_dropoff
    from public.task_instances ti
    join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id
    left join public.profiles p on p.user_id=ti.planned_assignee_id
    where ti.household_id=p_household_id and ti.scheduled_date=v_day and ti.test_context_id is null
      and td.code='dropoff' and ti.status in ('todo','in_progress')
    limit 1;
    select case when ti.planned_assignee_id=p_recipient and ti.recurrence_rule_id is not null
      and not private.fn_task_assignment_consent_v1(p_household_id,p_recipient,ti.id) then '相談中'
      else regexp_replace(coalesce(p.display_name,'未定'), '（仮）$', '') end into v_pickup
    from public.task_instances ti
    join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id
    left join public.profiles p on p.user_id=ti.planned_assignee_id
    where ti.household_id=p_household_id and ti.scheduled_date=v_day and ti.test_context_id is null
      and td.code='pickup' and ti.status in ('todo','in_progress')
    limit 1;

    select string_agg('・'||ti.title, E'\n' order by ti.due_at nulls last, ti.title) into v_special
    from public.task_instances ti
    where ti.household_id=p_household_id and ti.scheduled_date=v_day and ti.test_context_id is null
      and ti.calendar_visibility='special' and ti.status in ('todo','in_progress')
      and (ti.planned_assignee_id is distinct from p_recipient or ti.recurrence_rule_id is null
        or private.fn_task_assignment_consent_v1(p_household_id,p_recipient,ti.id));

    begin v_cal := private.fn_calendar_day_lines(p_household_id, v_day);
    exception when others then v_cal := null; end;
    begin
  with manual_hl as (
    select
      '・' || ti.title
        || coalesce(' (期限' || to_char(ti.due_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || ')', '') as line,
      ti.due_at as sort_ts
    from public.task_instances ti
    where ti.household_id = p_household_id
      and ti.origin = 'manual'
      and (ti.calendar_visibility is distinct from 'special' or ti.scheduled_date <> v_day)
      and ti.status in ('todo', 'in_progress')
      and ti.due_at is not null
      and (ti.due_at at time zone 'Asia/Tokyo')::date between v_day and v_day

  ),
  request_hl as (
    select
      '・' || r.shared_title
        || coalesce(' (期限' || to_char(r.due_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || ')', '') as line,
      r.due_at as sort_ts
    from public.requests r
    where r.household_id = p_household_id
      and r.status in ('pending', 'accepted')
      and r.due_at is not null
      and (r.due_at at time zone 'Asia/Tokyo')::date between v_day and v_day
  ),
  shopping_hl as (
    select
      '・' || si.title
        || coalesce(' (期限' || to_char(si.due_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || ')', '') as line,
      si.due_at as sort_ts
    from public.shopping_items si
    where si.household_id = p_household_id
      and si.status in ('wanted', 'assigned', 'ordered')
      and si.due_at is not null
      and (si.due_at at time zone 'Asia/Tokyo')::date between v_day and v_day
  )
  select string_agg(line, E'\n' order by sort_ts, line)
  into v_hl
  from (
    select * from manual_hl
    union all
    select * from request_hl
    union all
    select * from shopping_hl
  ) x;
    exception when others then v_hl := null; end;

    v_cal := private.fn_weekly_preview_lines_v1(v_cal, v_special, v_hl, v_dropoff is not null or v_pickup is not null);

    if v_dropoff is null and v_pickup is null and v_cal is null then
      continue;
    end if;
    v_block := to_char(v_day,'FMMM/FMDD')||'('||(array['月','火','水','木','金','土','日'])[extract(isodow from v_day)::int]||')'
      || case when v_dropoff is not null or v_pickup is not null
           then E'\n送り '||coalesce(v_dropoff,'-')||' / 迎え '||coalesce(v_pickup,'-') else '' end
      || coalesce(E'\n'||v_cal,'');
    v_out := v_out || case when v_out='' then '' else E'\n\n' end || v_block;
  end loop;
  return nullif(v_out,'');
end;
$$;
revoke all on function private.fn_render_weekly_preview_for_recipient_v1(uuid,date,uuid) from public,anon,authenticated;
grant execute on function private.fn_render_weekly_preview_for_recipient_v1(uuid,date,uuid) to service_role;

create or replace function public.server_tx_dispatch_daily_briefs(p_now timestamptz default now())
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_enabled boolean;
  r record;
  v_brief jsonb;
  v_receipt uuid;
  v_actor_ref uuid;
  v_dispatched int := 0;
  v_dedup text;
  v_mode text;
  v_body text;
  v_week text;
begin
  select writer_enabled and not mutation_paused and release_stage='P1' into v_enabled
  from private.canonical_capability_gates where capability='daily_brief_v2';
  if coalesce(v_enabled,false) is not true then
    return jsonb_build_object('enabled',false,'dispatched',0,'reason','CAPABILITY_NOT_AT_P1');
  end if;

  for r in select * from jsonb_to_recordset(public.server_read_due_daily_brief_slots(p_now)) as x(
    household_id uuid,recipient_user_id uuid,schedule_kind text,local_date date,
    local_time time,scheduled_at timestamptz,schedule_source text,dispatch_slot_key text
  ) loop
    v_receipt := null;
    insert into private.scheduled_dispatch_receipts(
      household_id,schedule_kind,scheduled_local_date,recipient_user_id,dispatch_slot_key
    ) values (r.household_id,r.schedule_kind,r.local_date,r.recipient_user_id,r.dispatch_slot_key)
    on conflict do nothing returning id into v_receipt;
    if v_receipt is null then continue; end if;

    v_brief := public.server_read_daily_brief(r.recipient_user_id,r.local_date);
    v_mode := case when r.schedule_kind='evening_brief' then 'evening' else 'morning' end;
    v_body := private.fn_render_daily_brief_text_v4(
      private.fn_daily_brief_for_line_v1(v_brief, r.recipient_user_id, r.scheduled_at, v_mode),
      case when v_mode='morning' then 'morning_focus' else v_mode end);

    v_week := null;
    if r.schedule_kind='nonworkday_morning_brief' and extract(isodow from r.local_date)=7 then
      begin
        v_week := private.fn_render_weekly_preview_for_recipient_v1(r.household_id, r.local_date + 1, r.recipient_user_id);
      exception when others then
        v_week := null; -- never lose the morning brief over the preview
      end;
      v_body := v_body || E'\n\n📅 来週の予定' || E'\n' || coalesce(v_week, '（登録された予定はありません）');
    end if;
    v_body := left(v_body, 5000); -- LINE text message limit

    select id into v_actor_ref from public.domain_actor_refs where household_id=r.household_id
      and actor_kind='real_user' and real_user_id=r.recipient_user_id;
    v_dedup := 'daily-brief:'||r.dispatch_slot_key;

    insert into public.user_notifications(
      household_id,recipient_user_id,type,title,body,payload,dedup_key,
      recipient_actor_ref_id,notification_kind,urgency,safety_class,bundle_key,
      business_expires_at,aggregate_type,aggregate_revision,test_context_id
    ) values (
      r.household_id,r.recipient_user_id,'daily_brief.v2',
      case when r.schedule_kind='evening_brief' then '夜のおうちノート' else '朝のおうちノート' end,
      v_body,
      jsonb_build_object('brief',v_brief,'schedule_kind',r.schedule_kind,
        'weekly_preview', v_week is not null),
      v_dedup,
      v_actor_ref,'daily_brief.v2','immediate','normal','daily-brief:'||r.recipient_user_id::text,
      r.scheduled_at+interval '8 hours','daily_brief',1,null
    ) on conflict(recipient_user_id,dedup_key) do nothing;
    v_dispatched := v_dispatched+1;
  end loop;

  return jsonb_build_object('enabled',true,'dispatched',v_dispatched);
end;
$$;

-- Suggestions are shown only to the definition's original designer and only
-- if a scheduled occurrence existed in the previous four weeks with no
-- completion or subtask/work-progress record from anyone. This is a private
-- review prompt, not a score for the person who was assigned the work.
create table private.assignment_review_snoozes (
  household_id uuid not null,
  actor_id uuid not null,
  definition_id uuid not null,
  until_date date not null,
  primary key(household_id,actor_id,definition_id),
  foreign key(household_id,actor_id) references public.household_members(household_id,user_id) on delete cascade,
  foreign key(household_id,definition_id) references public.task_definitions(household_id,id) on delete cascade
);
alter table private.assignment_review_snoozes enable row level security;
revoke all on private.assignment_review_snoozes from public,anon,authenticated;

create function private.fn_assignment_review_suggested_v1(p_household uuid,p_actor uuid,p_definition uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.task_definitions d
    where d.household_id=p_household and d.id=p_definition and d.created_by=p_actor and d.is_active
      and d.task_kind in ('morning_chore','evening_chore','morning_preparation','generic_once') and d.code not like 'codmon%'
      and coalesce(d.default_expectation,'required')<>'optional'
      and exists(select 1 from public.recurrence_rules r where r.household_id=d.household_id
        and r.task_definition_id=d.id and r.active and r.created_by=p_actor)
      and not exists(select 1 from private.assignment_review_snoozes s where s.household_id=d.household_id
        and s.actor_id=p_actor and s.definition_id=d.id and s.until_date>(now() at time zone 'Asia/Tokyo')::date)
      and exists(select 1 from public.task_instances t where t.household_id=d.household_id and t.task_definition_id=d.id
        and t.recurrence_rule_id is not null and t.test_context_id is null
        and t.scheduled_date>=(now() at time zone 'Asia/Tokyo')::date-28 and t.scheduled_date<(now() at time zone 'Asia/Tokyo')::date)
      and not exists(select 1 from public.task_instances t where t.household_id=d.household_id and t.task_definition_id=d.id
        and t.recurrence_rule_id is not null and t.test_context_id is null
        and ((t.status='completed' and t.completed_at>=now()-interval '28 days')
          or (t.status='skipped' and t.updated_at>=now()-interval '28 days')
          or exists(select 1 from public.task_events e where e.household_id=t.household_id
          and e.task_instance_id=t.id and e.test_context_id is null
          and e.created_at>=now()-interval '28 days'
          and e.event_type in ('completed','skipped','subtask_completed','work_progress_recorded'))))
  );
$$;
revoke all on function private.fn_assignment_review_suggested_v1(uuid,uuid,uuid) from public,anon,authenticated,service_role;

create function public.server_read_assignment_review_v1(p_actor_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare ctx jsonb; hh uuid; result jsonb; transport_tentative boolean;
begin
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id); hh:=(ctx->>'household_id')::uuid;
  select coalesce(jsonb_agg(jsonb_build_object('definition_id',d.id,'title',d.title,
    'review_suggested',private.fn_assignment_review_suggested_v1(hh,p_actor_id,d.id),
    'tentative',exists(
      select 1 from public.recurrence_rules r where r.household_id=hh and r.task_definition_id=d.id and r.active and r.created_by=p_actor_id
        and ((r.assignee_strategy='fixed' and r.planned_assignee_id is not null and r.planned_assignee_id<>p_actor_id
          and not private.fn_has_assignment_consent_v1(hh,r.planned_assignee_id,'rule',r.id))
        or (r.assignee_strategy not in ('fixed','unassigned','anyone_adult') and exists(
          select 1 from public.task_instances t where t.household_id=hh and t.recurrence_rule_id=r.id and t.test_context_id is null
            and t.planned_assignee_id is not null and t.planned_assignee_id<>p_actor_id
            and t.scheduled_date between (now() at time zone 'Asia/Tokyo')::date and (now() at time zone 'Asia/Tokyo')::date+28
            and not private.fn_has_assignment_consent_v1(hh,t.planned_assignee_id,'rule',r.id))))
  )) order by d.sort_order,d.title,d.id),'[]'::jsonb) into result
  from public.task_definitions d where d.household_id=hh and d.created_by=p_actor_id and d.is_active
    and d.task_kind<>'transport' and d.code not in ('dropoff','pickup')
    and exists(select 1 from public.recurrence_rules r where r.household_id=hh and r.task_definition_id=d.id and r.active and r.created_by=p_actor_id);
  select exists(select 1 from public.transport_weekly_templates t
    join public.transport_weekly_template_days day on day.household_id=t.household_id and day.template_id=t.id
    cross join lateral unnest(array[day.dropoff_user_id,day.pickup_user_id]) as member(user_id)
    where t.household_id=hh and t.created_by=p_actor_id and (t.valid_to is null or t.valid_to>=(now() at time zone 'Asia/Tokyo')::date)
      and t.valid_from<=(now() at time zone 'Asia/Tokyo')::date+28
      and member.user_id is not null and member.user_id<>p_actor_id
      and not private.fn_has_assignment_consent_v1(hh,member.user_id,'transport',t.id)) into transport_tentative;
  return jsonb_build_object('routines',result,'transport_tentative',transport_tentative);
end $$;
revoke all on function public.server_read_assignment_review_v1(uuid) from public,anon,authenticated;
grant execute on function public.server_read_assignment_review_v1(uuid) to service_role;

create function public.server_tx_review_assignment_v1(p_actor_id uuid,p_operation_id uuid,p_definition_id uuid,p_action text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb; hh uuid; actor_ref uuid; claim jsonb; receipt uuid; d public.task_definitions%rowtype; result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_definition_id is null or p_action is null or p_action not in ('keep','stop','optional') then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id); hh:=(ctx->>'household_id')::uuid; actor_ref:=(ctx->>'actor_ref_id')::uuid;
  claim:=private.fn_claim_canonical_operation_v1(hh,p_actor_id,actor_ref,null,p_operation_id,'assignment.review',
    private.fn_canonical_request_hash_v1(jsonb_build_object('definition_id',p_definition_id,'action',p_action)));
  if claim->>'disposition'='replay' then return claim->'result_payload'; end if;
  receipt:=(claim->>'receipt_id')::uuid;
  select * into d from public.task_definitions where household_id=hh and id=p_definition_id and created_by=p_actor_id for no key update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if not private.fn_assignment_review_suggested_v1(hh,p_actor_id,d.id) then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if p_action in ('stop','optional') then
    perform public.server_tx_set_routine_definition_options(p_actor_id,pg_catalog.md5(p_operation_id::text||':review-options')::uuid,
      d.id,p_action<>'stop',d.include_in_routine_line,case when p_action='optional' then 'optional' else null end);
  end if;
  insert into private.assignment_review_snoozes(household_id,actor_id,definition_id,until_date)
    values(hh,p_actor_id,d.id,(now() at time zone 'Asia/Tokyo')::date+28)
    on conflict(household_id,actor_id,definition_id) do update set until_date=excluded.until_date;
  result:=jsonb_build_object('ok',true,'action',p_action);
  perform private.fn_complete_canonical_operation_v1(receipt,'task_definition',d.id,result);
  return result;
end $$;
revoke all on function public.server_tx_review_assignment_v1(uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.server_tx_review_assignment_v1(uuid,uuid,uuid,text) to service_role;

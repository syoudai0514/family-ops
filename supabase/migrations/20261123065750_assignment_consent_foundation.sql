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
        from public.task_subtask_definitions s where s.household_id=d.household_id and s.task_definition_id=d.id),'[]'::jsonb))
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
            and (select count(*) from public.task_subtask_definitions s where s.household_id=hh and s.task_definition_id=d.id)<=8
            and not exists(select 1 from public.task_subtask_definitions s where s.household_id=hh
              and s.task_definition_id=d.id and char_length(s.title)>120)
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

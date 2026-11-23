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

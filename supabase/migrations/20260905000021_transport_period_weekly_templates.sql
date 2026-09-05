-- Issue #48 final UX contract / Q10 Q12 Q50 Q51 Q52.
-- Transport recurrence is managed as one period-scoped weekly template.  Daily
-- deviations are separate occurrence overrides.  Existing individually agreed
-- future occurrences are protected from template recalculation.

create table public.transport_weekly_templates (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  valid_from date not null,
  valid_to date null,
  created_by uuid not null,
  created_by_actor_ref_id uuid not null,
  revision bigint not null default 1 check(revision>=1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(household_id,id),
  foreign key(household_id,created_by) references public.household_members(household_id,user_id),
  foreign key(household_id,created_by_actor_ref_id) references public.domain_actor_refs(household_id,id),
  check(valid_to is null or valid_to>=valid_from)
);
create trigger set_updated_at before update on public.transport_weekly_templates
  for each row execute function public.set_updated_at();
alter table public.transport_weekly_templates
  add constraint transport_weekly_templates_no_overlap
  exclude using gist(
    household_id with =,
    daterange(valid_from,coalesce(valid_to,'infinity'::date),'[]') with &&
  );

create table public.transport_weekly_template_days (
  household_id uuid not null references public.households(id),
  template_id uuid not null,
  weekday smallint not null check(weekday between 1 and 7),
  dropoff_user_id uuid null,
  pickup_user_id uuid null,
  dropoff_local_time time null,
  pickup_local_time time null,
  primary key(template_id,weekday),
  foreign key(household_id,template_id) references public.transport_weekly_templates(household_id,id) on delete cascade,
  foreign key(household_id,dropoff_user_id) references public.household_members(household_id,user_id),
  foreign key(household_id,pickup_user_id) references public.household_members(household_id,user_id)
);
create index transport_template_days_household_idx on public.transport_weekly_template_days(household_id,template_id);

create table public.transport_occurrence_overrides (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  occurrence_date date not null,
  dropoff_overridden boolean not null default false,
  dropoff_user_id uuid null,
  pickup_overridden boolean not null default false,
  pickup_user_id uuid null,
  note text null check(note is null or octet_length(note)<=500),
  created_by uuid not null,
  created_by_actor_ref_id uuid not null,
  revision bigint not null default 1 check(revision>=1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(household_id,occurrence_date),
  unique(household_id,id),
  foreign key(household_id,dropoff_user_id) references public.household_members(household_id,user_id),
  foreign key(household_id,pickup_user_id) references public.household_members(household_id,user_id),
  foreign key(household_id,created_by) references public.household_members(household_id,user_id),
  foreign key(household_id,created_by_actor_ref_id) references public.domain_actor_refs(household_id,id),
  check(dropoff_overridden or pickup_overridden),
  check(dropoff_overridden or dropoff_user_id is null),
  check(pickup_overridden or pickup_user_id is null)
);
create trigger set_updated_at before update on public.transport_occurrence_overrides
  for each row execute function public.set_updated_at();

alter table public.transport_weekly_templates enable row level security;
alter table public.transport_weekly_template_days enable row level security;
alter table public.transport_occurrence_overrides enable row level security;
grant select on public.transport_weekly_templates,public.transport_weekly_template_days,public.transport_occurrence_overrides to authenticated;
create policy transport_weekly_templates_select on public.transport_weekly_templates
  for select to authenticated using(public.is_household_member(household_id));
create policy transport_weekly_template_days_select on public.transport_weekly_template_days
  for select to authenticated using(public.is_household_member(household_id));
create policy transport_occurrence_overrides_select on public.transport_occurrence_overrides
  for select to authenticated using(public.is_household_member(household_id));

alter table public.recurrence_rules
  add column transport_template_id uuid null,
  add column transport_leg text null check(transport_leg is null or transport_leg in ('dropoff','pickup')),
  add foreign key(household_id,transport_template_id)
    references public.transport_weekly_templates(household_id,id);
create index recurrence_rules_transport_template_idx
  on public.recurrence_rules(household_id,transport_template_id,transport_leg)
  where transport_template_id is not null;

-- Convert the currently effective legacy per-weekday setup into a template
-- starting on this migration date. Historical recurrence rows remain history;
-- this establishes the new UX contract prospectively without inventing past
-- template periods.
insert into public.transport_weekly_templates(
  household_id,valid_from,valid_to,created_by,created_by_actor_ref_id
)
select td.household_id,(now() at time zone 'Asia/Tokyo')::date,null,td.created_by,a.id
from public.task_definitions td
join public.domain_actor_refs a on a.household_id=td.household_id
  and a.actor_kind='real_user' and a.real_user_id=td.created_by
where td.code='dropoff'
  and not exists(select 1 from public.transport_weekly_templates t where t.household_id=td.household_id);

insert into public.transport_weekly_template_days(
  household_id,template_id,weekday,dropoff_user_id,pickup_user_id,dropoff_local_time,pickup_local_time
)
select t.household_id,t.id,d.weekday,
  dropoff.planned_assignee_id,pickup.planned_assignee_id,
  dropoff.scheduled_local_time,pickup.scheduled_local_time
from public.transport_weekly_templates t
cross join generate_series(1,7) d(weekday)
left join lateral(
  select r.planned_assignee_id,r.scheduled_local_time
  from public.recurrence_rules r join public.task_definitions td
    on td.household_id=r.household_id and td.id=r.task_definition_id
  where r.household_id=t.household_id and td.code='dropoff' and r.active
    and r.weekday=d.weekday
    and r.effective_from<=t.valid_from and (r.effective_to is null or r.effective_to>=t.valid_from)
  order by r.version desc,r.updated_at desc,r.id desc limit 1
) dropoff on true
left join lateral(
  select r.planned_assignee_id,r.scheduled_local_time
  from public.recurrence_rules r join public.task_definitions td
    on td.household_id=r.household_id and td.id=r.task_definition_id
  where r.household_id=t.household_id and td.code='pickup' and r.active
    and r.weekday=d.weekday
    and r.effective_from<=t.valid_from and (r.effective_to is null or r.effective_to>=t.valid_from)
  order by r.version desc,r.updated_at desc,r.id desc limit 1
) pickup on true;

update public.recurrence_rules r
set transport_template_id=t.id,
    transport_leg=td.code
from public.task_definitions td,public.transport_weekly_templates t
where td.household_id=r.household_id and td.id=r.task_definition_id
  and td.code in ('dropoff','pickup')
  and t.household_id=r.household_id
  and r.active and r.effective_from<=t.valid_from
  and (r.effective_to is null or r.effective_to>=t.valid_from)
  and r.transport_template_id is null;

create or replace function public.server_read_transport_templates(p_actor_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path=''
as $$
declare v_household_id uuid; v_templates jsonb; v_overrides jsonb;
begin
  select household_id into v_household_id from public.household_members where user_id=p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',t.id,'valid_from',t.valid_from,'valid_to',t.valid_to,'revision',t.revision,
    'days',coalesce(days.value,'[]'::jsonb)
  ) order by t.valid_from desc),'[]'::jsonb) into v_templates
  from public.transport_weekly_templates t
  left join lateral(
    select jsonb_agg(jsonb_build_object(
      'weekday',d.weekday,'dropoff_user_id',d.dropoff_user_id,'pickup_user_id',d.pickup_user_id,
      'dropoff_local_time',d.dropoff_local_time,'pickup_local_time',d.pickup_local_time
    ) order by d.weekday) value
    from public.transport_weekly_template_days d
    where d.household_id=t.household_id and d.template_id=t.id
  ) days on true
  where t.household_id=v_household_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',o.id,'occurrence_date',o.occurrence_date,
    'dropoff_overridden',o.dropoff_overridden,'dropoff_user_id',o.dropoff_user_id,
    'pickup_overridden',o.pickup_overridden,'pickup_user_id',o.pickup_user_id,
    'note',o.note,'revision',o.revision
  ) order by o.occurrence_date),'[]'::jsonb) into v_overrides
  from public.transport_occurrence_overrides o
  where o.household_id=v_household_id and o.occurrence_date >= (now() at time zone 'Asia/Tokyo')::date-31;
  return jsonb_build_object('templates',v_templates,'overrides',v_overrides);
end;
$$;

create or replace function public.server_tx_save_transport_template(
  p_actor_id uuid,p_operation_id uuid,p_valid_from date,p_days jsonb
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_context jsonb; v_household_id uuid; v_actor_ref uuid; v_claim jsonb; v_receipt_id uuid;
  v_previous public.transport_weekly_templates%rowtype; v_next public.transport_weekly_templates%rowtype;
  v_template_id uuid; v_valid_to date; v_day jsonb; v_weekday int; v_dropoff uuid; v_pickup uuid;
  v_dropoff_time time; v_pickup_time time; v_dropoff_def uuid; v_pickup_def uuid; v_rule_id uuid;
  v_horizon_end date; v_conflicts jsonb; v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_valid_from is null
     or jsonb_typeof(p_days)<>'array' or jsonb_array_length(p_days)<>7 then raise exception 'TRANSPORT_TEMPLATE_INVALID'; end if;
  if (select count(distinct (value->>'weekday')::int) from jsonb_array_elements(p_days))<>7
     or exists(select 1 from jsonb_array_elements(p_days) x where (x->>'weekday')::int not between 1 and 7) then
    raise exception 'TRANSPORT_TEMPLATE_WEEK_INVALID';
  end if;

  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  v_actor_ref:=(v_context->>'actor_ref_id')::uuid;
  v_claim:=private.fn_claim_canonical_operation_v1(
    v_household_id,p_actor_id,v_actor_ref,null,p_operation_id,'transport.template.save',
    private.fn_canonical_request_hash_v1(jsonb_build_object('valid_from',p_valid_from,'days',p_days))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;
  perform pg_advisory_xact_lock(hashtext('transport-template:'||v_household_id::text));

  if exists(select 1 from public.transport_weekly_templates where household_id=v_household_id and valid_from=p_valid_from) then
    raise exception 'TRANSPORT_TEMPLATE_START_EXISTS';
  end if;

  for v_day in select value from jsonb_array_elements(p_days) loop
    v_dropoff:=nullif(v_day->>'dropoff_user_id','')::uuid;
    v_pickup:=nullif(v_day->>'pickup_user_id','')::uuid;
    if v_dropoff is not null and not exists(select 1 from public.household_members where household_id=v_household_id and user_id=v_dropoff) then
      raise exception 'CROSS_HOUSEHOLD_RESOURCE';
    end if;
    if v_pickup is not null and not exists(select 1 from public.household_members where household_id=v_household_id and user_id=v_pickup) then
      raise exception 'CROSS_HOUSEHOLD_RESOURCE';
    end if;
  end loop;

  select * into v_previous from public.transport_weekly_templates
    where household_id=v_household_id and valid_from<p_valid_from
    order by valid_from desc limit 1 for update;
  select * into v_next from public.transport_weekly_templates
    where household_id=v_household_id and valid_from>p_valid_from
    order by valid_from asc limit 1 for update;
  v_valid_to:=case when v_next.id is null then null else v_next.valid_from-1 end;
  if v_previous.id is not null and (v_previous.valid_to is null or v_previous.valid_to>=p_valid_from) then
    update public.transport_weekly_templates set valid_to=p_valid_from-1,revision=revision+1 where id=v_previous.id;
  end if;

  insert into public.transport_weekly_templates(
    household_id,valid_from,valid_to,created_by,created_by_actor_ref_id
  ) values(v_household_id,p_valid_from,v_valid_to,p_actor_id,v_actor_ref)
  returning id into v_template_id;

  for v_day in select value from jsonb_array_elements(p_days) loop
    v_weekday:=(v_day->>'weekday')::int;
    v_dropoff:=nullif(v_day->>'dropoff_user_id','')::uuid;
    v_pickup:=nullif(v_day->>'pickup_user_id','')::uuid;
    v_dropoff_time:=nullif(v_day->>'dropoff_local_time','')::time;
    v_pickup_time:=nullif(v_day->>'pickup_local_time','')::time;
    insert into public.transport_weekly_template_days(
      household_id,template_id,weekday,dropoff_user_id,pickup_user_id,dropoff_local_time,pickup_local_time
    ) values(v_household_id,v_template_id,v_weekday,v_dropoff,v_pickup,v_dropoff_time,v_pickup_time);
  end loop;

  select id into v_dropoff_def from public.task_definitions where household_id=v_household_id and code='dropoff';
  select id into v_pickup_def from public.task_definitions where household_id=v_household_id and code='pickup';
  if v_dropoff_def is null or v_pickup_def is null then raise exception 'TRANSPORT_DEFINITIONS_REQUIRED'; end if;

  -- Close the previous template's rules and supersede legacy one-by-one rules
  -- in the new period. Rules belonging to a later persisted template are left
  -- intact when inserting into historical gaps.
  update public.recurrence_rules r set effective_to=p_valid_from-1
  where r.household_id=v_household_id and r.active
    and r.transport_template_id=v_previous.id and r.effective_from<p_valid_from
    and (r.effective_to is null or r.effective_to>=p_valid_from);
  update public.recurrence_rules r set active=false
  where r.household_id=v_household_id and r.active
    and r.task_definition_id in (v_dropoff_def,v_pickup_def)
    and r.transport_template_id is null
    and daterange(r.effective_from,coalesce(r.effective_to,'infinity'::date),'[]') &&
        daterange(p_valid_from,coalesce(v_valid_to,'infinity'::date),'[]');

  for v_day in select value from jsonb_array_elements(p_days) loop
    v_weekday:=(v_day->>'weekday')::int;
    v_dropoff:=nullif(v_day->>'dropoff_user_id','')::uuid;
    v_pickup:=nullif(v_day->>'pickup_user_id','')::uuid;
    v_dropoff_time:=nullif(v_day->>'dropoff_local_time','')::time;
    v_pickup_time:=nullif(v_day->>'pickup_local_time','')::time;
    if v_dropoff is not null then
      insert into public.recurrence_rules(
        household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,
        scheduled_local_time,effective_from,effective_to,active,version,created_by,transport_template_id,transport_leg
      ) values(v_household_id,v_dropoff_def,v_weekday,'default','fixed',v_dropoff,v_dropoff_time,
        p_valid_from,v_valid_to,true,1,p_actor_id,v_template_id,'dropoff') returning id into v_rule_id;
    end if;
    if v_pickup is not null then
      insert into public.recurrence_rules(
        household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,
        scheduled_local_time,effective_from,effective_to,active,version,created_by,transport_template_id,transport_leg
      ) values(v_household_id,v_pickup_def,v_weekday,'default','fixed',v_pickup,v_pickup_time,
        p_valid_from,v_valid_to,true,1,p_actor_id,v_template_id,'pickup') returning id into v_rule_id;
    end if;
  end loop;

  -- Update only unprotected rule-derived future occurrences. Human agreement,
  -- explicit override, manual assignment, cancellation or reassigned_once rows
  -- survive and their logical occurrence key prevents rematerialization.
  with candidates as (
    select ti.id,
      nr.id new_rule_id,nr.planned_assignee_id new_user_id,nr.scheduled_local_time,
      ar.id new_actor_ref
    from public.task_instances ti
    join public.task_definitions td on td.household_id=ti.household_id and td.id=ti.task_definition_id
    left join public.recurrence_rules nr on nr.household_id=ti.household_id
      and nr.transport_template_id=v_template_id and nr.task_definition_id=ti.task_definition_id
      and nr.weekday=extract(isodow from ti.scheduled_date)::smallint and nr.active
    left join public.domain_actor_refs ar on ar.household_id=ti.household_id
      and ar.actor_kind='real_user' and ar.real_user_id=nr.planned_assignee_id
    where ti.household_id=v_household_id and td.code in ('dropoff','pickup')
      and ti.origin='recurring' and ti.scheduled_date>=p_valid_from
      and (v_valid_to is null or ti.scheduled_date<=v_valid_to)
      and ti.status in ('todo','in_progress','cancelled')
      and coalesce(ti.assignment_source,'legacy_snapshot')='legacy_snapshot'
      and not (ti.source_context ? 'transport_occurrence_override')
      and not exists(select 1 from public.task_events e where e.household_id=ti.household_id and e.task_instance_id=ti.id and e.event_type in ('reassigned_once','cancelled'))
  )
  update public.task_instances ti
  set recurrence_rule_id=c.new_rule_id,
      planned_assignee_id=c.new_user_id,
      planned_assignee_actor_ref_id=c.new_actor_ref,
      assignment_mode=case when c.new_user_id is null then 'unassigned' else 'person' end,
      assignment_source='legacy_snapshot',
      due_at=case when c.scheduled_local_time is null then null else
        ((ti.scheduled_date::text||' '||c.scheduled_local_time::text)::timestamp at time zone 'Asia/Tokyo') end,
      status=case when c.new_rule_id is null then 'cancelled' when ti.status='cancelled' then 'todo' else ti.status end,
      revision=ti.revision+1
  from candidates c where ti.id=c.id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',ti.id,'date',ti.scheduled_date,'leg',td.code,
    'planned_assignee_user_id',ti.planned_assignee_id,'assignment_source',ti.assignment_source
  ) order by ti.scheduled_date,td.code),'[]'::jsonb) into v_conflicts
  from public.task_instances ti join public.task_definitions td
    on td.household_id=ti.household_id and td.id=ti.task_definition_id
  where ti.household_id=v_household_id and td.code in ('dropoff','pickup')
    and ti.scheduled_date>=p_valid_from and (v_valid_to is null or ti.scheduled_date<=v_valid_to)
    and ti.status in ('todo','in_progress','completed','skipped','cancelled')
    and (
      coalesce(ti.assignment_source,'legacy_snapshot')<>'legacy_snapshot'
      or ti.source_context ? 'transport_occurrence_override'
      or exists(select 1 from public.task_events e where e.household_id=ti.household_id and e.task_instance_id=ti.id and e.event_type in ('reassigned_once','cancelled'))
    );

  v_horizon_end:=least(coalesce(v_valid_to,((now() at time zone 'Asia/Tokyo')::date+90)),((now() at time zone 'Asia/Tokyo')::date+90));
  if p_valid_from<=v_horizon_end then
    for v_rule_id in select id from public.recurrence_rules where household_id=v_household_id and transport_template_id=v_template_id and active loop
      perform private.materialize_recurrence_rule(v_household_id,v_rule_id,p_valid_from,v_horizon_end);
    end loop;
  end if;

  v_result:=jsonb_build_object(
    'template_id',v_template_id,'valid_from',p_valid_from,'valid_to',v_valid_to,
    'protected_conflicts',v_conflicts
  );
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'transport_weekly_template',v_template_id,v_result);
  return v_result;
end;
$$;

create or replace function public.server_tx_set_transport_occurrence_override(
  p_actor_id uuid,p_operation_id uuid,p_occurrence_date date,
  p_dropoff_overridden boolean,p_dropoff_user_id uuid,
  p_pickup_overridden boolean,p_pickup_user_id uuid,p_note text default null
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_context jsonb; v_household_id uuid; v_actor_ref uuid; v_claim jsonb; v_receipt_id uuid;
  v_override public.transport_occurrence_overrides%rowtype; v_leg text; v_is_override boolean; v_user uuid;
  v_def public.task_definitions%rowtype; v_task public.task_instances%rowtype; v_assignee_ref uuid; v_rule public.recurrence_rules%rowtype;
  v_logical_key text; v_due_at timestamptz; v_result jsonb;
begin
  if p_occurrence_date is null or coalesce(p_dropoff_overridden,false)=false and coalesce(p_pickup_overridden,false)=false then
    raise exception 'TRANSPORT_OVERRIDE_EMPTY';
  end if;
  if not coalesce(p_dropoff_overridden,false) and p_dropoff_user_id is not null then raise exception 'TRANSPORT_OVERRIDE_INVALID'; end if;
  if not coalesce(p_pickup_overridden,false) and p_pickup_user_id is not null then raise exception 'TRANSPORT_OVERRIDE_INVALID'; end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid; v_actor_ref:=(v_context->>'actor_ref_id')::uuid;
  if p_dropoff_user_id is not null and not exists(select 1 from public.household_members where household_id=v_household_id and user_id=p_dropoff_user_id) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if p_pickup_user_id is not null and not exists(select 1 from public.household_members where household_id=v_household_id and user_id=p_pickup_user_id) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  v_claim:=private.fn_claim_canonical_operation_v1(v_household_id,p_actor_id,v_actor_ref,null,p_operation_id,'transport.occurrence_override.set',
    private.fn_canonical_request_hash_v1(jsonb_build_object('date',p_occurrence_date,'dropoff_overridden',p_dropoff_overridden,'dropoff_user_id',p_dropoff_user_id,'pickup_overridden',p_pickup_overridden,'pickup_user_id',p_pickup_user_id,'note',p_note)));
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;

  insert into public.transport_occurrence_overrides(
    household_id,occurrence_date,dropoff_overridden,dropoff_user_id,pickup_overridden,pickup_user_id,note,created_by,created_by_actor_ref_id
  ) values(v_household_id,p_occurrence_date,p_dropoff_overridden,p_dropoff_user_id,p_pickup_overridden,p_pickup_user_id,nullif(btrim(coalesce(p_note,'')),''),p_actor_id,v_actor_ref)
  on conflict(household_id,occurrence_date) do update set
    dropoff_overridden=excluded.dropoff_overridden,dropoff_user_id=excluded.dropoff_user_id,
    pickup_overridden=excluded.pickup_overridden,pickup_user_id=excluded.pickup_user_id,
    note=excluded.note,revision=public.transport_occurrence_overrides.revision+1
  returning * into v_override;

  for v_leg,v_is_override,v_user in
    select * from (values('dropoff',p_dropoff_overridden,p_dropoff_user_id),('pickup',p_pickup_overridden,p_pickup_user_id)) x(leg,is_override,user_id)
  loop
    if not v_is_override then continue; end if;
    select * into v_def from public.task_definitions where household_id=v_household_id and code=v_leg;
    if not found then raise exception 'TRANSPORT_DEFINITIONS_REQUIRED'; end if;
    v_logical_key:='rec:'||v_def.id::text||':'||p_occurrence_date::text||':default';
    select * into v_task from public.task_instances where household_id=v_household_id and logical_occurrence_key=v_logical_key for update;
    select r.* into v_rule from public.recurrence_rules r
      where r.household_id=v_household_id and r.task_definition_id=v_def.id and r.active
        and r.weekday=extract(isodow from p_occurrence_date)::smallint
        and r.effective_from<=p_occurrence_date and (r.effective_to is null or r.effective_to>=p_occurrence_date)
      order by r.effective_from desc,r.id desc limit 1;
    v_assignee_ref:=null;
    if v_user is not null then select id into v_assignee_ref from public.domain_actor_refs where household_id=v_household_id and actor_kind='real_user' and real_user_id=v_user; end if;
    v_due_at:=case when v_rule.scheduled_local_time is null then null else ((p_occurrence_date::text||' '||v_rule.scheduled_local_time::text)::timestamp at time zone 'Asia/Tokyo') end;
    if v_task.id is null then
      insert into public.task_instances(
        household_id,task_definition_id,recurrence_rule_id,logical_occurrence_key,origin,title,category,routine_phase,
        scheduled_date,due_at,planned_assignee_id,completion_mode,status,source,created_by,
        assignment_mode,assignment_source,planned_assignee_actor_ref_id,source_context
      ) values(
        v_household_id,v_def.id,v_rule.id,v_logical_key,'recurring',v_def.title,v_def.category,v_def.routine_phase,
        p_occurrence_date,v_due_at,v_user,v_def.completion_mode,case when v_user is null then 'cancelled' else 'todo' end,
        'recurring',p_actor_id,case when v_user is null then 'unassigned' else 'person' end,'occurrence_override',v_assignee_ref,
        jsonb_build_object('transport_occurrence_override',v_override.id,'transport_leg',v_leg)
      ) returning * into v_task;
    else
      if v_task.status in ('completed','skipped') then raise exception 'TRANSPORT_OCCURRENCE_TERMINAL'; end if;
      if v_task.status='cancelled' and not (v_task.source_context ? 'transport_occurrence_override') then raise exception 'TRANSPORT_OCCURRENCE_PROTECTED'; end if;
      update public.task_instances set
        planned_assignee_id=v_user,planned_assignee_actor_ref_id=v_assignee_ref,
        assignment_mode=case when v_user is null then 'unassigned' else 'person' end,
        assignment_source='occurrence_override',due_at=v_due_at,
        status=case when v_user is null then 'cancelled' when status='cancelled' then 'todo' else status end,
        source_context=source_context||jsonb_build_object('transport_occurrence_override',v_override.id,'transport_leg',v_leg),
        revision=revision+1
      where id=v_task.id;
    end if;
    insert into public.task_events(household_id,task_instance_id,actor_id,actor_ref_id,event_type,payload,source,idempotency_key)
      values(v_household_id,v_task.id,p_actor_id,v_actor_ref,'reassigned_once',jsonb_build_object('transport_override_id',v_override.id,'leg',v_leg,'planned_assignee_user_id',v_user),'pwa','transport-override:'||p_operation_id::text||':'||v_leg);
  end loop;

  v_result:=jsonb_build_object('override_id',v_override.id,'occurrence_date',p_occurrence_date,'revision',v_override.revision);
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'transport_occurrence_override',v_override.id,v_result);
  return v_result;
end;
$$;

create or replace function public.server_tx_delete_transport_occurrence_override(
  p_actor_id uuid,p_operation_id uuid,p_occurrence_date date
) returns jsonb
language plpgsql security invoker set search_path=''
as $$
declare
  v_context jsonb; v_household_id uuid; v_actor_ref uuid; v_claim jsonb; v_receipt_id uuid;
  v_override public.transport_occurrence_overrides%rowtype; v_leg text; v_was_override boolean;
  v_def public.task_definitions%rowtype; v_task public.task_instances%rowtype; v_base_user uuid; v_base_time time; v_base_ref uuid;
  v_result jsonb;
begin
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid; v_actor_ref:=(v_context->>'actor_ref_id')::uuid;
  v_claim:=private.fn_claim_canonical_operation_v1(v_household_id,p_actor_id,v_actor_ref,null,p_operation_id,'transport.occurrence_override.delete',
    private.fn_canonical_request_hash_v1(jsonb_build_object('date',p_occurrence_date)));
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;
  select * into v_override from public.transport_occurrence_overrides
    where household_id=v_household_id and occurrence_date=p_occurrence_date for update;
  if not found then raise exception 'TRANSPORT_OVERRIDE_NOT_FOUND'; end if;

  for v_leg,v_was_override in select * from (values('dropoff',v_override.dropoff_overridden),('pickup',v_override.pickup_overridden)) x(leg,was_override) loop
    if not v_was_override then continue; end if;
    select * into v_def from public.task_definitions where household_id=v_household_id and code=v_leg;
    select case when v_leg='dropoff' then d.dropoff_user_id else d.pickup_user_id end,
           case when v_leg='dropoff' then d.dropoff_local_time else d.pickup_local_time end
      into v_base_user,v_base_time
    from public.transport_weekly_templates t join public.transport_weekly_template_days d
      on d.household_id=t.household_id and d.template_id=t.id
    where t.household_id=v_household_id and p_occurrence_date>=t.valid_from
      and (t.valid_to is null or p_occurrence_date<=t.valid_to)
      and d.weekday=extract(isodow from p_occurrence_date)::smallint
    order by t.valid_from desc limit 1;
    v_base_ref:=null;
    if v_base_user is not null then select id into v_base_ref from public.domain_actor_refs where household_id=v_household_id and actor_kind='real_user' and real_user_id=v_base_user; end if;
    select * into v_task from public.task_instances
      where household_id=v_household_id and logical_occurrence_key='rec:'||v_def.id::text||':'||p_occurrence_date::text||':default' for update;
    if v_task.id is not null and v_task.source_context->>'transport_occurrence_override'=v_override.id::text
       and v_task.status not in ('completed','skipped') then
      update public.task_instances set
        planned_assignee_id=v_base_user,planned_assignee_actor_ref_id=v_base_ref,
        assignment_mode=case when v_base_user is null then 'unassigned' else 'person' end,
        assignment_source='legacy_snapshot',
        due_at=case when v_base_time is null then null else ((p_occurrence_date::text||' '||v_base_time::text)::timestamp at time zone 'Asia/Tokyo') end,
        status=case when v_base_user is null then 'cancelled' when status='cancelled' then 'todo' else status end,
        source_context=(source_context-'transport_occurrence_override'-'transport_leg'),revision=revision+1
      where id=v_task.id;
      insert into public.task_events(household_id,task_instance_id,actor_id,actor_ref_id,event_type,payload,source,idempotency_key)
        values(v_household_id,v_task.id,p_actor_id,v_actor_ref,'transport_override_removed',jsonb_build_object('transport_override_id',v_override.id,'leg',v_leg),'pwa','transport-override-delete:'||p_operation_id::text||':'||v_leg);
    end if;
  end loop;

  delete from public.transport_occurrence_overrides where id=v_override.id;
  v_result:=jsonb_build_object('deleted',true,'occurrence_date',p_occurrence_date);
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'transport_occurrence_override',v_override.id,v_result);
  return v_result;
end;
$$;

revoke all on function public.server_read_transport_templates(uuid) from public,anon,authenticated;
revoke all on function public.server_tx_save_transport_template(uuid,uuid,date,jsonb) from public,anon,authenticated;
revoke all on function public.server_tx_set_transport_occurrence_override(uuid,uuid,date,boolean,uuid,boolean,uuid,text) from public,anon,authenticated;
revoke all on function public.server_tx_delete_transport_occurrence_override(uuid,uuid,date) from public,anon,authenticated;
grant execute on function public.server_read_transport_templates(uuid) to service_role;
grant execute on function public.server_tx_save_transport_template(uuid,uuid,date,jsonb) to service_role;
grant execute on function public.server_tx_set_transport_occurrence_override(uuid,uuid,date,boolean,uuid,boolean,uuid,text) to service_role;
grant execute on function public.server_tx_delete_transport_occurrence_override(uuid,uuid,date) to service_role;

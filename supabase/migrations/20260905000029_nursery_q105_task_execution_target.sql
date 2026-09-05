-- Issue #48 / Appendix A Q105 closeout.
-- A reviewed URL / QR destination is not merely provenance: after human
-- confirmation it becomes a household-visible execution target on the exact
-- canonical Todo. Low-confidence candidates remain review-only; the PWA keeps
-- them unselected by default. No external navigation/provider side effect is
-- performed by this migration.

create table public.task_execution_targets (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  task_instance_id uuid not null,
  target_kind text not null check (target_kind in ('url','destination')),
  label text null check (label is null or (length(btrim(label)) between 1 and 160)),
  url text null,
  destination text null,
  created_by_actor_ref_id uuid not null,
  created_at timestamptz not null default now(),
  unique (household_id,task_instance_id),
  foreign key (household_id,task_instance_id)
    references public.task_instances(household_id,id) on delete cascade,
  foreign key (household_id,created_by_actor_ref_id)
    references public.domain_actor_refs(household_id,id),
  check (
    (target_kind='url' and url ~* '^https?://[^[:space:]]+$' and destination is null)
    or
    (target_kind='destination' and url is null and length(btrim(destination)) between 1 and 500)
  )
);

alter table public.task_execution_targets enable row level security;
grant select on public.task_execution_targets to authenticated;
grant select,insert,update,delete on public.task_execution_targets to service_role;
create policy task_execution_targets_select on public.task_execution_targets
for select to authenticated using (public.is_household_member(household_id));
create index task_execution_targets_task_idx
  on public.task_execution_targets(household_id,task_instance_id);

create or replace function private.fn_validate_nursery_execution_target_review_v1(p_value jsonb)
returns void
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_key text;
  v_url text;
  v_destination text;
begin
  perform private.fn_nursery_safe_confirmed_value(p_value);
  if p_value is null or jsonb_typeof(p_value)<>'object'
     or octet_length(p_value::text)>2048 then
    raise exception 'NURSERY_REVIEW_VALUE_INVALID';
  end if;
  for v_key in select jsonb_object_keys(p_value) loop
    if v_key not in ('title','due_date','url','destination') then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;
    if jsonb_typeof(p_value->v_key) not in ('string','null') then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;
  end loop;
  if nullif(btrim(coalesce(p_value->>'title','')),'') is null
     or length(p_value->>'title')>240 then
    raise exception 'NURSERY_REVIEW_VALUE_INVALID';
  end if;
  v_url:=nullif(btrim(coalesce(p_value->>'url','')),'');
  v_destination:=nullif(btrim(coalesce(p_value->>'destination','')),'');
  if (v_url is null)=(v_destination is null) then
    raise exception 'NURSERY_EXECUTION_TARGET_REQUIRED';
  end if;
  if v_url is not null and v_url !~* '^https?://[^[:space:]]+$' then
    raise exception 'NURSERY_UNSAFE_URL';
  end if;
  if v_destination is not null and length(v_destination)>500 then
    raise exception 'NURSERY_REVIEW_VALUE_INVALID';
  end if;
end;
$$;
revoke all on function private.fn_validate_nursery_execution_target_review_v1(jsonb)
  from public,anon,authenticated;
grant execute on function private.fn_validate_nursery_execution_target_review_v1(jsonb) to service_role;

-- Migration 28 introduced the generic durable-row guard. Replace only its
-- URL/destination branch; every other item kind continues through the strict
-- kind validator unchanged.
create or replace function private.fn_guard_nursery_review_item_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.candidate_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$' then
    raise exception 'NURSERY_REVIEW_CANDIDATE_KEY_INVALID';
  end if;
  if new.source_locator is not null
     and new.source_locator !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$' then
    raise exception 'NURSERY_SOURCE_LOCATOR_INVALID';
  end if;
  if new.item_kind='timetable' then
    if new.classification not in ('recommended','other') then
      raise exception 'NURSERY_TIMETABLE_CLASS_REQUIRED';
    end if;
  elsif new.classification is not null then
    raise exception 'NURSERY_CLASSIFICATION_INVALID';
  end if;

  if new.item_kind='url' then
    perform private.fn_validate_nursery_execution_target_review_v1(new.proposed_value);
  else
    perform private.fn_validate_nursery_review_value_by_kind_v1(new.item_kind,new.proposed_value);
  end if;
  return new;
end;
$$;

create or replace function private.fn_attach_nursery_execution_target_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_url text;
  v_destination text;
  v_kind text;
begin
  if new.item_kind<>'url' then return new; end if;
  if new.created_task_id is null then raise exception 'NURSERY_EXECUTION_TARGET_TASK_REQUIRED'; end if;
  perform private.fn_validate_nursery_execution_target_review_v1(new.confirmed_value - 'add_to_calendar');
  v_url:=nullif(btrim(coalesce(new.confirmed_value->>'url','')),'');
  v_destination:=nullif(btrim(coalesce(new.confirmed_value->>'destination','')),'');
  v_kind:=case when v_url is not null then 'url' else 'destination' end;

  insert into public.task_execution_targets(
    household_id,task_instance_id,target_kind,label,url,destination,created_by_actor_ref_id
  ) values(
    new.household_id,new.created_task_id,v_kind,
    nullif(btrim(coalesce(new.confirmed_value->>'title','')),''),
    v_url,v_destination,new.confirmed_by_actor_ref_id
  );
  return new;
end;
$$;
revoke all on function private.fn_attach_nursery_execution_target_v1()
  from public,anon,authenticated;
grant execute on function private.fn_attach_nursery_execution_target_v1() to service_role;

drop trigger if exists nursery_confirmed_execution_target_v1 on public.nursery_confirmed_items;
create trigger nursery_confirmed_execution_target_v1
after insert on public.nursery_confirmed_items
for each row execute function private.fn_attach_nursery_execution_target_v1();

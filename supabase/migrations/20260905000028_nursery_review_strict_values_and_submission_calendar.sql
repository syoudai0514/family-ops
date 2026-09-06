-- Issue #48 / Appendix A Q99 + Q104 closeout.
--
-- Q99: nursery pre-review rows are durable, therefore they must not become a
-- generic JSON/free-text side channel. Validate every item kind at the DB
-- boundary with a small allow-list. The image worker is not a trust boundary.
--
-- Q104: a submission notice always becomes a due Todo after human confirmation;
-- Google Calendar is an explicit human opt-in. The image/AI candidate is never
-- allowed to select Calendar. Confirmation starts hidden and this post-confirm
-- projection changes only the chosen task to `special`, which can enqueue the
-- existing Family Ops calendar outbox but never mutates Google directly.

create or replace function private.fn_validate_nursery_flat_value_v1(
  p_value jsonb,
  p_allowed_keys text[],
  p_required_keys text[] default '{}'
)
returns void
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_key text;
  v_val jsonb;
  v_count integer;
begin
  if p_value is null or jsonb_typeof(p_value) <> 'object'
     or octet_length(p_value::text) > 2048 then
    raise exception 'NURSERY_REVIEW_VALUE_INVALID';
  end if;

  select count(*)::integer into v_count from jsonb_object_keys(p_value);
  if v_count > greatest(1, cardinality(p_allowed_keys)) then
    raise exception 'NURSERY_REVIEW_VALUE_INVALID';
  end if;

  for v_key, v_val in select key, value from jsonb_each(p_value) loop
    if not (v_key = any(p_allowed_keys)) then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;
    if jsonb_typeof(v_val) not in ('string','number','boolean','null') then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;
    if jsonb_typeof(v_val) = 'string' and length(v_val #>> '{}') > 1000 then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;
  end loop;

  foreach v_key in array coalesce(p_required_keys,'{}'::text[]) loop
    if not (p_value ? v_key)
       or p_value->v_key is null
       or jsonb_typeof(p_value->v_key) = 'null'
       or (jsonb_typeof(p_value->v_key) = 'string' and btrim(p_value->>v_key) = '') then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;
  end loop;
end;
$$;

create or replace function private.fn_validate_nursery_rule_spec_v1(p_value jsonb)
returns void
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_key text;
  v_val jsonb;
  v_element jsonb;
  v_count integer;
begin
  if p_value is null or jsonb_typeof(p_value) <> 'object'
     or octet_length(p_value::text) > 1024 then
    raise exception 'NURSERY_REVIEW_VALUE_INVALID';
  end if;
  select count(*)::integer into v_count from jsonb_object_keys(p_value);
  if v_count < 1 or v_count > 8 then raise exception 'NURSERY_REVIEW_VALUE_INVALID'; end if;

  for v_key, v_val in select key, value from jsonb_each(p_value) loop
    if v_key not in ('frequency','weekday','weekdays','day_of_month','month','interval','anchor_date','condition') then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;
    if jsonb_typeof(v_val) = 'array' then
      if jsonb_array_length(v_val) > 16 then raise exception 'NURSERY_REVIEW_VALUE_INVALID'; end if;
      for v_element in select value from jsonb_array_elements(v_val) loop
        if jsonb_typeof(v_element) not in ('string','number','boolean')
           or (jsonb_typeof(v_element)='string' and length(v_element #>> '{}')>80) then
          raise exception 'NURSERY_REVIEW_VALUE_INVALID';
        end if;
      end loop;
    elsif jsonb_typeof(v_val) not in ('string','number','boolean','null')
       or (jsonb_typeof(v_val)='string' and length(v_val #>> '{}')>120) then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;
  end loop;
end;
$$;

create or replace function private.fn_validate_nursery_review_value_by_kind_v1(
  p_kind text,
  p_value jsonb
)
returns void
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_allowed text[];
  v_key text;
begin
  perform private.fn_nursery_safe_confirmed_value(p_value);

  if p_kind = 'preparation' then
    if p_value is null or jsonb_typeof(p_value) <> 'object'
       or octet_length(p_value::text) > 4096
       or not (p_value ? 'trigger_spec')
       or not (p_value ? 'preparation_template') then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;
    for v_key in select jsonb_object_keys(p_value) loop
      if v_key not in ('trigger_spec','preparation_template','effective_from','effective_to') then
        raise exception 'NURSERY_REVIEW_VALUE_INVALID';
      end if;
    end loop;
    perform private.fn_validate_nursery_preparation_trigger_v1(p_value->'trigger_spec');
    perform private.fn_validate_nursery_preparation_template_v1(p_value->'preparation_template');
    if p_value ? 'effective_from' and jsonb_typeof(p_value->'effective_from') <> 'string' then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;
    if p_value ? 'effective_to' and jsonb_typeof(p_value->'effective_to') not in ('string','null') then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;

  elsif p_kind = 'task' then
    perform private.fn_validate_nursery_flat_value_v1(
      p_value,array['title','due_date'],array['title']
    );

  elsif p_kind = 'submission' then
    -- add_to_calendar is deliberately absent here. It is injected only by the
    -- authenticated human review UI at confirmation time.
    perform private.fn_validate_nursery_flat_value_v1(
      p_value,array['title','due_date'],array['title','due_date']
    );

  elsif p_kind = 'timetable' then
    perform private.fn_validate_nursery_flat_value_v1(
      p_value,array['title','date','location','details'],array['title','date']
    );

  elsif p_kind = 'shared_info' then
    perform private.fn_validate_nursery_flat_value_v1(
      p_value,array['text','date','title'],array['text']
    );

  elsif p_kind = 'url' then
    perform private.fn_validate_nursery_flat_value_v1(
      p_value,array['title','due_date','url','destination'],array['title','url']
    );
    if coalesce(p_value->>'url','') !~* '^https?://[^[:space:]]+$' then
      raise exception 'NURSERY_UNSAFE_URL';
    end if;

  elsif p_kind = 'recurrence' then
    if p_value is null or jsonb_typeof(p_value) <> 'object'
       or octet_length(p_value::text) > 2048 then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;
    for v_key in select jsonb_object_keys(p_value) loop
      if v_key not in ('effective_from','effective_to','rule_spec') then
        raise exception 'NURSERY_REVIEW_VALUE_INVALID';
      end if;
    end loop;
    if not (p_value ? 'effective_from') or not (p_value ? 'effective_to') or not (p_value ? 'rule_spec')
       or jsonb_typeof(p_value->'effective_from') <> 'string'
       or jsonb_typeof(p_value->'effective_to') <> 'string' then
      raise exception 'NURSERY_REVIEW_VALUE_INVALID';
    end if;
    perform private.fn_validate_nursery_rule_spec_v1(p_value->'rule_spec');

  elsif p_kind = 'exception' then
    perform private.fn_validate_nursery_flat_value_v1(
      p_value,array['series_id','occurrence_date','action','title','due_date'],array['series_id','occurrence_date']
    );

  else
    raise exception 'NURSERY_REVIEW_ITEM_INVALID';
  end if;
end;
$$;

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
  if new.item_kind = 'timetable' then
    if new.classification not in ('recommended','other') then
      raise exception 'NURSERY_TIMETABLE_CLASS_REQUIRED';
    end if;
  elsif new.classification is not null then
    raise exception 'NURSERY_CLASSIFICATION_INVALID';
  end if;
  perform private.fn_validate_nursery_review_value_by_kind_v1(new.item_kind,new.proposed_value);
  return new;
end;
$$;

revoke all on function private.fn_validate_nursery_flat_value_v1(jsonb,text[],text[]) from public,anon,authenticated;
revoke all on function private.fn_validate_nursery_rule_spec_v1(jsonb) from public,anon,authenticated;
revoke all on function private.fn_validate_nursery_review_value_by_kind_v1(text,jsonb) from public,anon,authenticated;
revoke all on function private.fn_guard_nursery_review_item_v1() from public,anon,authenticated;
grant execute on function private.fn_validate_nursery_flat_value_v1(jsonb,text[],text[]) to service_role;
grant execute on function private.fn_validate_nursery_rule_spec_v1(jsonb) to service_role;
grant execute on function private.fn_validate_nursery_review_value_by_kind_v1(text,jsonb) to service_role;
grant execute on function private.fn_guard_nursery_review_item_v1() to service_role;

drop trigger if exists nursery_review_items_strict_value_v1 on private.nursery_review_items;
create trigger nursery_review_items_strict_value_v1
before insert or update of candidate_key,item_kind,classification,source_locator,proposed_value
on private.nursery_review_items
for each row execute function private.fn_guard_nursery_review_item_v1();

create or replace function private.fn_apply_nursery_submission_calendar_choice_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_choice boolean := false;
begin
  if new.item_kind <> 'submission' then
    if new.confirmed_value ? 'add_to_calendar' then
      raise exception 'NURSERY_CALENDAR_CHOICE_INVALID';
    end if;
    return new;
  end if;

  if new.confirmed_value ? 'add_to_calendar' then
    if jsonb_typeof(new.confirmed_value->'add_to_calendar') <> 'boolean' then
      raise exception 'NURSERY_SUBMISSION_CALENDAR_INVALID';
    end if;
    v_choice := (new.confirmed_value->>'add_to_calendar')::boolean;
  end if;

  if new.created_task_id is null then
    raise exception 'NURSERY_SUBMISSION_TASK_REQUIRED';
  end if;

  if v_choice then
    update public.task_instances
    set calendar_visibility = 'special'
    where household_id = new.household_id
      and id = new.created_task_id
      and test_context_id is null;
    if not found then raise exception 'NURSERY_SUBMISSION_TASK_SCOPE_INVALID'; end if;
  end if;

  return new;
end;
$$;

revoke all on function private.fn_apply_nursery_submission_calendar_choice_v1() from public,anon,authenticated;
grant execute on function private.fn_apply_nursery_submission_calendar_choice_v1() to service_role;

drop trigger if exists nursery_confirmed_submission_calendar_choice_v1 on public.nursery_confirmed_items;
create trigger nursery_confirmed_submission_calendar_choice_v1
after insert on public.nursery_confirmed_items
for each row execute function private.fn_apply_nursery_submission_calendar_choice_v1();

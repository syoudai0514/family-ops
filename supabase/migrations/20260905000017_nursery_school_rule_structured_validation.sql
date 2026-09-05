-- Issue #48 Q91/Q94/Q95 closeout.
--
-- The generic DD9 pre-review validator intentionally rejects nested JSON to
-- eliminate durable covert channels. A human-confirmed school preparation rule
-- is a different, post-review aggregate and legitimately needs a small nested
-- checklist structure. Keep the generic validator strict; validate this final
-- rule with a dedicated allow-list instead.

create or replace function private.fn_validate_nursery_preparation_trigger_v1(p_value jsonb)
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
     or octet_length(p_value::text) > 2048 then
    raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
  end if;

  select count(*)::integer into v_count from jsonb_object_keys(p_value);
  if v_count > 8 then raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID'; end if;

  for v_key, v_val in select key, value from jsonb_each(p_value) loop
    if v_key not in ('event','event_type','weekday','month','date','condition','title_contains','classification') then
      raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
    end if;
    if jsonb_typeof(v_val) = 'array' then
      if jsonb_array_length(v_val) > 16 then raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID'; end if;
      for v_element in select value from jsonb_array_elements(v_val) loop
        if jsonb_typeof(v_element) not in ('string','number','boolean') then
          raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
        end if;
        if jsonb_typeof(v_element) = 'string' and length(v_element #>> '{}') > 120 then
          raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
        end if;
      end loop;
    elsif jsonb_typeof(v_val) not in ('string','number','boolean','null') then
      raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
    elsif jsonb_typeof(v_val) = 'string' and length(v_val #>> '{}') > 240 then
      raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
    end if;
  end loop;
end;
$$;

create or replace function private.fn_validate_nursery_preparation_template_v1(p_value jsonb)
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
  v_element_key text;
  v_element_value jsonb;
  v_count integer;
begin
  if p_value is null or jsonb_typeof(p_value) <> 'object'
     or octet_length(p_value::text) > 4096 then
    raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
  end if;

  select count(*)::integer into v_count from jsonb_object_keys(p_value);
  if v_count > 6 then raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID'; end if;

  for v_key, v_val in select key, value from jsonb_each(p_value) loop
    -- Legacy/canonical DD9 confirmation already stores a single preparation as
    -- {"item":"..."}. Keep that exact confirmed aggregate valid without
    -- reopening the pre-review validator or allowing arbitrary top-level keys.
    if v_key in ('item','title','category') then
      if jsonb_typeof(v_val) not in ('string','null')
         or (jsonb_typeof(v_val) = 'string'
             and (length(btrim(v_val #>> '{}')) < 1 or length(v_val #>> '{}') > 240)) then
        raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
      end if;
    elsif v_key = 'quantity' then
      if jsonb_typeof(v_val) not in ('string','number','null')
         or (jsonb_typeof(v_val) = 'string'
             and (length(btrim(v_val #>> '{}')) < 1 or length(v_val #>> '{}') > 120)) then
        raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
      end if;
    elsif v_key in ('note','notes') then
      if jsonb_typeof(v_val) not in ('string','null')
         or (jsonb_typeof(v_val) = 'string' and length(v_val #>> '{}') > 500) then
        raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
      end if;
    elsif v_key in ('items','tasks','checklist') then
      if jsonb_typeof(v_val) <> 'array' or jsonb_array_length(v_val) > 32 then
        raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
      end if;
      for v_element in select value from jsonb_array_elements(v_val) loop
        if jsonb_typeof(v_element) = 'string' then
          if length(btrim(v_element #>> '{}')) < 1 or length(v_element #>> '{}') > 160 then
            raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
          end if;
        elsif jsonb_typeof(v_element) = 'object' then
          select count(*)::integer into v_count from jsonb_object_keys(v_element);
          if v_count > 4 then raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID'; end if;
          for v_element_key, v_element_value in select key, value from jsonb_each(v_element) loop
            if v_element_key not in ('title','quantity','note','category')
               or jsonb_typeof(v_element_value) not in ('string','number','boolean','null') then
              raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
            end if;
            if jsonb_typeof(v_element_value) = 'string' and length(v_element_value #>> '{}') > 240 then
              raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
            end if;
          end loop;
          if nullif(btrim(coalesce(v_element->>'title','')),'') is null then
            raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
          end if;
        else
          raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
        end if;
      end loop;
    else
      raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID';
    end if;
  end loop;
end;
$$;

revoke all on function private.fn_validate_nursery_preparation_trigger_v1(jsonb)
  from public, anon, authenticated;
revoke all on function private.fn_validate_nursery_preparation_template_v1(jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_validate_nursery_preparation_trigger_v1(jsonb) to service_role;
grant execute on function private.fn_validate_nursery_preparation_template_v1(jsonb) to service_role;

create or replace function private.fn_command_confirm_school_preparation_rule_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_test_context_id uuid,
  p_operation_id uuid,p_child_school_context_id uuid,p_trigger_spec jsonb,p_preparation_template jsonb,
  p_effective_from date,p_effective_to date,p_source text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_claim jsonb; v_receipt_id uuid; v_rule_id uuid; v_result jsonb;
begin
  if p_test_context_id is not null then raise exception 'TEST_SIDE_EFFECT_FORBIDDEN'; end if;
  if p_source not in ('line','pwa') or p_effective_from is null
     or (p_effective_to is not null and p_effective_to<p_effective_from) then
    raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID'; end if;
  perform private.fn_validate_nursery_preparation_trigger_v1(p_trigger_spec);
  perform private.fn_validate_nursery_preparation_template_v1(p_preparation_template);
  if not exists (select 1 from public.child_school_contexts s
    where s.household_id=p_household_id and s.id=p_child_school_context_id and s.active) then
    raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end if;
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,null,p_operation_id,
    'nursery.preparation_rule.confirm',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'child_school_context_id',p_child_school_context_id,'trigger_spec',p_trigger_spec,
      'preparation_template',p_preparation_template,'effective_from',p_effective_from,
      'effective_to',p_effective_to,'source',p_source
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;
  insert into public.school_preparation_rules(
    household_id,child_school_context_id,trigger_spec,preparation_template,confirmed_by_actor_ref_id,
    effective_from,effective_to
  ) values (
    p_household_id,p_child_school_context_id,p_trigger_spec,p_preparation_template,p_actor_ref_id,
    p_effective_from,p_effective_to
  ) returning id into v_rule_id;
  v_result:=jsonb_build_object('school_preparation_rule_id',v_rule_id,'confirmed',true);
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'school_preparation_rule',v_rule_id,v_result);
  return v_result;
end;
$$;

revoke all on function private.fn_command_confirm_school_preparation_rule_v1(uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb,date,date,text)
  from public, anon, authenticated;
grant execute on function private.fn_command_confirm_school_preparation_rule_v1(uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb,date,date,text)
  to service_role;

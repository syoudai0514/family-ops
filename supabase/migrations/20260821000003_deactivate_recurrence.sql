-- Explicit recurrence disable: preserves completed history and removes only future todo work.
create or replace function public.server_tx_deactivate_recurrence(
  p_actor_id uuid, p_operation_id uuid, p_task_definition_id uuid, p_weekday int, p_slot_key text default null
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_household uuid; v_rule public.recurrence_rules%rowtype; v_today date := (now() at time zone 'Asia/Tokyo')::date; v_hash text; v_receipt record; v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_definition_id is null or p_weekday not between 1 and 7 then raise exception 'INVALID_INPUT'; end if;
  v_hash := encode(sha256(convert_to('deactivate-recurrence|'||p_task_definition_id||'|'||p_weekday||'|'||coalesce(p_slot_key,'default'),'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash) values(p_actor_id,p_operation_id,'deactivate-recurrence',v_hash) on conflict(actor_id,operation_id) do nothing;
  if not found then select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id; if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return v_receipt.result_payload; end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id; if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  if not exists(select 1 from public.task_definitions where id=p_task_definition_id and household_id=v_household) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  select * into v_rule from public.recurrence_rules where household_id=v_household and task_definition_id=p_task_definition_id and weekday=p_weekday and slot_key=coalesce(nullif(btrim(p_slot_key),''),'default') and active order by version desc limit 1;
  if found then update public.recurrence_rules set active=false,effective_to=greatest(v_today-1,v_rule.effective_from) where id=v_rule.id; delete from public.task_instances where recurrence_rule_id=v_rule.id and household_id=v_household and scheduled_date>=v_today and status='todo'; end if;
  v_result:=jsonb_build_object('deactivated',true,'task_definition_id',p_task_definition_id,'weekday',p_weekday); update private.mutation_receipts set result_type='recurrence_rule',result_id=coalesce(v_rule.id,p_task_definition_id),result_payload=v_result where actor_id=p_actor_id and operation_id=p_operation_id; return v_result;
end $$;
revoke all on function public.server_tx_deactivate_recurrence(uuid,uuid,uuid,int,text) from public,anon,authenticated;
grant execute on function public.server_tx_deactivate_recurrence(uuid,uuid,uuid,int,text) to service_role;

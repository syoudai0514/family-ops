-- LINE-native natural-language actions. Forward-only migration.
-- Clear LINE input is converted to a canonical pending action, previewed back
-- to the sender, and only executed after the existing confirm_pending postback.
-- General partner requests create recipient-owned accept/decline pending
-- actions so the existing LINE postback contract can finish the flow without PWA.

-- ---------------------------------------------------------------------------
-- 1) Natural-language draft worker queue over private.pending_actions.
--    No new table: state is kept in normalized_payload and stale processing
--    claims are reclaimable after two minutes.
-- ---------------------------------------------------------------------------
create or replace function public.server_tx_claim_line_draft_batch(
  p_limit int default 20
) returns table(
  id uuid,
  household_id uuid,
  actor_id uuid,
  action_type text,
  normalized_payload jsonb
)
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then raise exception 'INVALID_INPUT'; end if;
  return query
  with candidates as (
    select pa.id
    from private.pending_actions pa
    where pa.source = 'line'
      and pa.status = 'draft'
      and pa.expires_at > now()
      and pa.action_type in ('needs_pwa_review','task_create_once','shopping_item_add')
      and (
        coalesce(pa.normalized_payload->>'line_intent_state','') in ('','ready_preview')
        or (
          pa.normalized_payload->>'line_intent_state' = 'processing'
          and coalesce((pa.normalized_payload->>'line_intent_claimed_at')::timestamptz, '-infinity'::timestamptz) < now() - interval '2 minutes'
        )
      )
    order by pa.created_at
    for update skip locked
    limit p_limit
  ), claimed as (
    update private.pending_actions pa
    set normalized_payload = jsonb_set(
          jsonb_set(pa.normalized_payload, '{line_intent_state}', '"processing"'::jsonb, true),
          '{line_intent_claimed_at}', to_jsonb(now()::text), true
        ),
        updated_at = now()
    from candidates c
    where pa.id = c.id
    returning pa.id, pa.household_id, pa.actor_id, pa.action_type, pa.normalized_payload
  )
  select claimed.id, claimed.household_id, claimed.actor_id, claimed.action_type, claimed.normalized_payload
  from claimed;
end;
$$;

create or replace function public.server_tx_prepare_line_pending_preview(
  p_id uuid,
  p_action_type text,
  p_normalized_payload jsonb
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare v_result jsonb;
begin
  if p_id is null
     or p_action_type not in ('shopping_item_add','task_create_once','request_create','needs_pwa_review')
     or p_normalized_payload is null or jsonb_typeof(p_normalized_payload) <> 'object' then
    raise exception 'INVALID_INPUT';
  end if;
  update private.pending_actions
  set action_type = p_action_type,
      normalized_payload = jsonb_set(
        p_normalized_payload - 'line_intent_claimed_at',
        '{line_intent_state}', '"ready_preview"'::jsonb, true
      ),
      updated_at = now()
  where id = p_id and source = 'line' and status = 'draft' and expires_at > now()
  returning jsonb_build_object(
    'id', id, 'household_id', household_id, 'actor_id', actor_id,
    'action_type', action_type, 'normalized_payload', normalized_payload
  ) into v_result;
  if v_result is null then raise exception 'PENDING_ACTION_NOT_EDITABLE'; end if;
  return v_result;
end;
$$;

create or replace function public.server_tx_mark_line_pending_previewed(
  p_id uuid
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare v_result jsonb;
begin
  update private.pending_actions
  set normalized_payload = jsonb_set(
        normalized_payload - 'line_intent_claimed_at',
        '{line_intent_state}', '"previewed"'::jsonb, true
      ),
      updated_at = now()
  where id = p_id and source = 'line' and status = 'draft'
  returning jsonb_build_object('ok', true, 'id', id) into v_result;
  if v_result is null then raise exception 'PENDING_ACTION_NOT_EDITABLE'; end if;
  return v_result;
end;
$$;

create or replace function public.server_tx_mark_line_pending_parse_failed(
  p_id uuid
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare v_result jsonb;
begin
  update private.pending_actions
  set normalized_payload = jsonb_set(
        normalized_payload - 'line_intent_claimed_at',
        '{line_intent_state}', '"parse_failed"'::jsonb, true
      ),
      updated_at = now()
  where id = p_id and source = 'line' and status = 'draft'
  returning jsonb_build_object('ok', true, 'id', id) into v_result;
  if v_result is null then raise exception 'PENDING_ACTION_NOT_EDITABLE'; end if;
  return v_result;
end;
$$;

revoke all on function public.server_tx_claim_line_draft_batch(int) from public, anon, authenticated;
revoke all on function public.server_tx_prepare_line_pending_preview(uuid,text,jsonb) from public, anon, authenticated;
revoke all on function public.server_tx_mark_line_pending_previewed(uuid) from public, anon, authenticated;
revoke all on function public.server_tx_mark_line_pending_parse_failed(uuid) from public, anon, authenticated;
grant execute on function public.server_tx_claim_line_draft_batch(int) to service_role;
grant execute on function public.server_tx_prepare_line_pending_preview(uuid,text,jsonb) to service_role;
grant execute on function public.server_tx_mark_line_pending_previewed(uuid) to service_role;
grant execute on function public.server_tx_mark_line_pending_parse_failed(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 2) General request creation: full idempotency + recipient-owned LINE action
--    rows. Raw sender LINE text never enters requests/user_notifications.
-- ---------------------------------------------------------------------------
create or replace function public.server_tx_send_request(
  p_actor_id uuid,
  p_operation_id uuid,
  p_recipient_user_id uuid,
  p_shared_title text,
  p_shared_message text,
  p_due_at timestamptz
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text; v_receipt record; v_household_id uuid; v_request_id uuid;
  v_accept_action_id uuid; v_decline_action_id uuid; v_result jsonb; v_expiry timestamptz;
begin
  if p_actor_id is null or p_operation_id is null or p_recipient_user_id is null
     or coalesce(btrim(p_shared_title),'') = '' or p_recipient_user_id = p_actor_id then
    raise exception 'INVALID_INPUT';
  end if;
  v_request_hash := encode(sha256(convert_to(
    concat_ws('|','send-request-v2',p_recipient_user_id::text,btrim(p_shared_title),
      coalesce(btrim(p_shared_message),''),coalesce(p_due_at::text,'')), 'UTF8')), 'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
    values(p_actor_id,p_operation_id,'send-request-v2',v_request_hash)
    on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
      where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash<>v_request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result_payload;
  end loop;

  select household_id into v_household_id from public.household_members where user_id=p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  if not exists(select 1 from public.household_members where household_id=v_household_id and user_id=p_recipient_user_id)
    then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;

  insert into public.requests(household_id,requester_id,recipient_id,shared_title,shared_message,due_at,status)
  values(v_household_id,p_actor_id,p_recipient_user_id,btrim(p_shared_title),
    nullif(btrim(coalesce(p_shared_message,'')),''),p_due_at,'pending')
  returning id into v_request_id;

  v_expiry := greatest(now()+interval '24 hours', coalesce(p_due_at+interval '6 hours', now()+interval '24 hours'));
  insert into private.pending_actions(household_id,actor_id,source,action_type,normalized_payload,operation_id,status,expires_at)
  values(v_household_id,p_recipient_user_id,'line','request_accept',jsonb_build_object('request_id',v_request_id),gen_random_uuid(),'draft',v_expiry)
  returning id into v_accept_action_id;
  insert into private.pending_actions(household_id,actor_id,source,action_type,normalized_payload,operation_id,status,expires_at)
  values(v_household_id,p_recipient_user_id,'line','request_decline',jsonb_build_object('request_id',v_request_id),gen_random_uuid(),'draft',v_expiry)
  returning id into v_decline_action_id;

  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
  values(v_household_id,p_recipient_user_id,'request_received',btrim(p_shared_title),
    coalesce(nullif(btrim(p_shared_message),''),btrim(p_shared_title)),
    jsonb_build_object(
      'request_id',v_request_id,'request_kind','general','due_at',p_due_at,
      'accept_pending_action_id',v_accept_action_id,'decline_pending_action_id',v_decline_action_id
    ), p_operation_id::text||':request_received');

  v_result:=jsonb_build_object('request_id',v_request_id);
  update private.mutation_receipts set result_type='request',result_id=v_request_id,result_payload=v_result
    where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;
revoke all on function public.server_tx_send_request(uuid,uuid,uuid,text,text,timestamptz) from public,anon,authenticated;
grant execute on function public.server_tx_send_request(uuid,uuid,uuid,text,text,timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- 3) Enrich request LINE outbox rows. Assignment-change keeps its existing
--    metadata path; a general request additionally carries a prebuilt Flex
--    card whose buttons use the already-supported confirm_pending action.
-- ---------------------------------------------------------------------------
create or replace function private.fn_enrich_line_outbox_request_payload()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare v_rich jsonb; v_due_label text;
begin
  if new.type <> 'request_received' or coalesce(new.payload->>'request_id','')='' then return new; end if;

  if new.payload->>'request_kind'='general'
     and coalesce(new.payload->>'accept_pending_action_id','')<>''
     and coalesce(new.payload->>'decline_pending_action_id','')<>'' then
    v_due_label := case when new.payload->>'due_at' is null then null
      else to_char((new.payload->>'due_at')::timestamptz at time zone 'Asia/Tokyo','MM/DD HH24:MI') end;
    v_rich := jsonb_build_object(
      'type','flex','altText','お願い: '||new.title,
      'contents',jsonb_build_object(
        'type','bubble',
        'body',jsonb_build_object('type','box','layout','vertical','spacing','md','contents',
          jsonb_strip_nulls(jsonb_build_array(
            jsonb_build_object('type','text','text','お願いが届いています','weight','bold','size','sm','color','#166B5D'),
            jsonb_build_object('type','text','text',new.title,'weight','bold','size','xl','wrap',true),
            case when v_due_label is null then null else jsonb_build_object('type','text','text',v_due_label,'size','sm','color','#555555') end,
            jsonb_build_object('type','text','text',coalesce(new.body,'お願いできますか？'),'wrap',true,'color','#555555'),
            jsonb_build_object('type','text','text','引き受けるまでタスクにはなりません。','size','xs','wrap',true,'color','#777777')
          ))),
        'footer',jsonb_build_object('type','box','layout','vertical','spacing','sm','contents',jsonb_build_array(
          jsonb_build_object('type','button','style','primary','action',jsonb_build_object(
            'type','postback','label','引き受ける','data','action=confirm_pending&pending_action_id='||(new.payload->>'accept_pending_action_id'),'displayText','引き受ける')),
          jsonb_build_object('type','button','style','secondary','action',jsonb_build_object(
            'type','postback','label','今回は難しい','data','action=confirm_pending&pending_action_id='||(new.payload->>'decline_pending_action_id'),'displayText','今回は難しい'))
        ))
      )
    );
  end if;

  update private.notification_outbox o
  set payload = case when v_rich is null then
        jsonb_set(o.payload,'{items}',(
          select jsonb_agg(case when item->>'user_notification_id'=new.id::text
            then item||jsonb_build_object('payload',new.payload) else item end)
          from jsonb_array_elements(coalesce(o.payload->'items','[]'::jsonb)) item),true)
      else
        jsonb_set(
          jsonb_set(o.payload,'{items}',(
            select jsonb_agg(case when item->>'user_notification_id'=new.id::text
              then item||jsonb_build_object('payload',new.payload) else item end)
            from jsonb_array_elements(coalesce(o.payload->'items','[]'::jsonb)) item),true),
          '{rich_message}',v_rich,true)
      end
  where o.household_id=new.household_id and o.recipient_user_id=new.recipient_user_id
    and o.status='queued'
    and o.payload @> jsonb_build_object('items',jsonb_build_array(jsonb_build_object('user_notification_id',new.id)));
  return new;
end;
$$;
revoke all on function private.fn_enrich_line_outbox_request_payload() from public,anon,authenticated;
grant execute on function private.fn_enrich_line_outbox_request_payload() to service_role;

-- An expiring UI selection, never request/consent truth. Keep it on the existing
-- actor/household-bound LINE link; unlink/relink cannot revive an old selection.
alter table private.line_user_links add column request_context jsonb;

create function public.server_tx_line_request_context(
  p_actor_id uuid,
  p_action text,
  p_context jsonb default null
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  v_link private.line_user_links%rowtype;
  v_self uuid;
  v_context jsonb;
begin
  if p_actor_id is null or p_action is null or p_action not in ('get','set','clear') then raise exception 'INVALID_INPUT'; end if;
  select l.* into v_link from private.line_user_links l
  join public.household_members m on m.household_id=l.household_id and m.user_id=l.user_id
  where l.user_id=p_actor_id and l.status='active' and m.member_role='adult' for update of l;
  if not found then raise exception 'LINE_LINK_NOT_ACTIVE'; end if;
  if p_action='clear' then
    update private.line_user_links set request_context=null where id=v_link.id;
    return null;
  end if;
  if p_action='get' then
    if v_link.request_context is null then return null; end if;
    if (v_link.request_context->>'expires_at')::timestamptz<=clock_timestamp()
      or (v_link.request_context->>'selected_at')::timestamptz<v_link.linked_at then
      return jsonb_build_object('expired',true);
    end if;
    return v_link.request_context;
  end if;
  select id into v_self from public.domain_actor_refs where household_id=v_link.household_id
    and real_user_id=p_actor_id and actor_kind='real_user' and test_context_id is null;
  if not exists (
    select 1 from public.requests r join public.request_attempts a on a.request_id=r.id
    where r.id=(p_context->>'request_id')::uuid and a.id=(p_context->>'attempt_id')::uuid
      and r.household_id=v_link.household_id and a.household_id=v_link.household_id
      and r.test_context_id is null and a.test_context_id is null
      and v_self in (r.requester_actor_ref_id,r.recipient_actor_ref_id)
      and a.revision=(p_context->>'revision')::bigint
      and a.terms_revision=(p_context->>'terms_revision')::bigint
      and a.state in ('pending','checking','consulting','awaiting_confirmation','expired')
      and not exists(select 1 from public.request_attempts newer where newer.request_id=r.id
        and newer.household_id=v_link.household_id and newer.test_context_id is null
        and newer.id<>a.id and newer.created_at>=a.created_at)
  ) then raise exception 'REQUEST_ATTEMPT_STALE'; end if;
  if coalesce(p_context->>'mode','selected') not in ('selected','decline_comment')
    or char_length(coalesce(p_context->>'comment',''))>500 then raise exception 'INVALID_INPUT'; end if;
  v_context:=jsonb_build_object(
    'request_id',(p_context->>'request_id')::uuid,'attempt_id',(p_context->>'attempt_id')::uuid,
    'revision',(p_context->>'revision')::bigint,'terms_revision',(p_context->>'terms_revision')::bigint,
    'mode',coalesce(p_context->>'mode','selected'),'comment',p_context->>'comment',
    'preview_id',(p_context->>'preview_id')::uuid,
    'selected_at',clock_timestamp(),'expires_at',clock_timestamp()+interval '15 minutes');
  update private.line_user_links set request_context=v_context where id=v_link.id;
  return v_context;
end; $$;
revoke all on function public.server_tx_line_request_context(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_line_request_context(uuid,text,jsonb) to service_role;

-- The existing canonical transition owns authorization, attempt state and
-- operation receipt. A comment extends that same decline and same delivery;
-- it never creates another request lifecycle or a second notification.
create function public.server_tx_line_decline_request_comment(
  p_actor_id uuid, p_operation_id uuid, p_request_id uuid, p_attempt_id uuid,
  p_comment text, p_expected_revision bigint, p_expected_terms_revision integer
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  c jsonb; result jsonb; comment_text text:=btrim(coalesce(p_comment,''));
  n public.user_notifications%rowtype;
begin
  if char_length(comment_text) not between 1 and 500 then raise exception 'INVALID_INPUT'; end if;
  c:=private.fn_require_production_actor_context_v1(p_actor_id);
  result:=public.server_tx_transition_request_v2(p_actor_id,p_operation_id,p_request_id,p_attempt_id,
    'decline',jsonb_build_object('comment',comment_text),p_expected_revision,p_expected_terms_revision,'line');
  -- Expiry can be committed by the canonical command between preview and send.
  if result->>'state' is distinct from 'declined' then return result; end if;
  update public.request_attempts set terms=coalesce(terms,'{}'::jsonb)||jsonb_build_object('decline_comment',comment_text)
    where id=p_attempt_id and request_id=p_request_id and household_id=(c->>'household_id')::uuid;
  for n in update public.user_notifications un
    set body=r.shared_title||E'\n返答: '||comment_text,
      payload=un.payload||jsonb_build_object('decline_comment',comment_text)
    from public.requests r
    where r.id=p_request_id and r.household_id=(c->>'household_id')::uuid
      and un.household_id=r.household_id and un.type='request.declined'
      and un.payload->>'request_id'=p_request_id::text and un.payload->>'attempt_id'=p_attempt_id::text
    returning un.*
  loop
    update private.notification_outbox o set payload=jsonb_set(o.payload,'{items}',(
      select jsonb_agg(case when item->>'user_notification_id'=n.id::text
        then item||jsonb_build_object('body',n.body,'payload',n.payload) else item end order by ordinal)
      from jsonb_array_elements(o.payload->'items') with ordinality as e(item,ordinal)
    )) where o.household_id=n.household_id and o.recipient_user_id=n.recipient_user_id
      and o.payload->'items' @> jsonb_build_array(jsonb_build_object('user_notification_id',n.id));
  end loop;
  return result;
end; $$;
revoke all on function public.server_tx_line_decline_request_comment(uuid,uuid,uuid,uuid,text,bigint,integer) from public,anon,authenticated;
grant execute on function public.server_tx_line_decline_request_comment(uuid,uuid,uuid,uuid,text,bigint,integer) to service_role;

-- Q72 + Q4/Q70/Q71 integration without replacing the established LINE
-- worker.  The inbox claim adapter returns a parser-only copy of message text
-- with this sender's confirmed household terminology applied.  The durable
-- webhook payload itself remains byte-for-byte untouched.  Draft edits keep
-- the worker's existing 4-argument call shape, but that adapter is now safe:
-- it derives the sole serialized provider event and delegates to the guarded
-- revision + event-watermark mutation.

create or replace function private.fn_apply_confirmed_household_terminology_v1(
  p_household_id uuid,
  p_text text
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_work text;
  v_row record;
  v_token text;
  v_tokens text[] := '{}';
  v_meanings text[] := '{}';
  v_i int;
begin
  if p_household_id is null or p_text is null then return p_text; end if;
  v_work := normalize(p_text, NFKC);

  -- First replace phrases with private-use sentinels, longest first.  Meanings
  -- are substituted only in the second pass, so a shorter household term can
  -- never recursively reinterpret text introduced by a longer mapping.
  for v_row in
    select id,
           normalize(btrim(phrase), NFKC) as phrase,
           normalize(btrim(meaning), NFKC) as meaning
    from public.household_terminology
    where household_id = p_household_id
      and confirmed_at is not null
    order by char_length(normalize(btrim(phrase), NFKC)) desc, id
  loop
    if v_row.phrase = '' or v_row.meaning = '' or v_row.phrase = v_row.meaning then
      continue;
    end if;
    v_token := chr(57344) || replace(v_row.id::text, '-', '') || chr(57345);
    if strpos(v_work, v_row.phrase) > 0 then
      v_work := replace(v_work, v_row.phrase, v_token);
      v_tokens := array_append(v_tokens, v_token);
      v_meanings := array_append(v_meanings, v_row.meaning);
    end if;
  end loop;

  if coalesce(array_length(v_tokens, 1), 0) > 0 then
    for v_i in 1..array_length(v_tokens, 1) loop
      v_work := replace(v_work, v_tokens[v_i], v_meanings[v_i]);
    end loop;
  end if;
  return v_work;
end;
$$;
revoke all on function private.fn_apply_confirmed_household_terminology_v1(uuid, text)
  from public, anon, authenticated;
grant execute on function private.fn_apply_confirmed_household_terminology_v1(uuid, text)
  to service_role;

create or replace function private.fn_line_parser_payload_v1(
  p_line_user_id text,
  p_payload jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_text text;
  v_normalized text;
begin
  if p_payload is null
     or p_payload->>'type' <> 'message'
     or p_payload#>>'{message,type}' <> 'text'
     or coalesce(p_line_user_id, '') = '' then
    return p_payload;
  end if;

  select link.household_id into v_household_id
  from private.line_user_links link
  where link.line_user_id = p_line_user_id
    and link.status = 'active'
  order by link.linked_at desc nulls last
  limit 1;
  if v_household_id is null then return p_payload; end if;

  v_text := p_payload#>>'{message,text}';
  if v_text is null then return p_payload; end if;

  -- The literal six-entry/menu command surface is product grammar, not a
  -- household alias.  A household term may never shadow these entry points.
  if regexp_replace(normalize(v_text, NFKC), '\s+', '', 'g')
       in ('今日','入力','追加','お願い','共有','その他','メニュー','明日','今週') then
    return p_payload;
  end if;

  v_normalized := private.fn_apply_confirmed_household_terminology_v1(
    v_household_id, v_text
  );
  if v_normalized is not distinct from v_text then return p_payload; end if;

  -- This is only the claimed worker copy. private.webhook_inbox.payload keeps
  -- the original LINE event, so audit/idempotency/provenance do not change.
  return jsonb_set(p_payload, '{message,text}', to_jsonb(v_normalized), false);
end;
$$;
revoke all on function private.fn_line_parser_payload_v1(text, jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_line_parser_payload_v1(text, jsonb) to service_role;

create or replace function public.server_tx_claim_webhook_inbox_batch(
  p_worker_id text,
  p_limit int,
  p_lease_seconds int
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if coalesce(p_worker_id, '') = '' or p_limit is null or p_limit <= 0
     or p_lease_seconds is null or p_lease_seconds <= 0 then
    raise exception 'INVALID_INPUT';
  end if;

  with eligible as (
    select w.id,
           row_number() over (
             partition by coalesce(w.source_external_user_id, w.id::text)
             order by coalesce(nullif(w.payload->>'timestamp','')::bigint, 0), w.received_at, w.id
           ) as sender_rank
    from private.webhook_inbox w
    where (
      (w.status = 'received' and w.next_attempt_at <= now())
      or (w.status = 'processing' and w.lease_until < now())
    )
      and not exists (
        select 1
        from private.webhook_inbox busy
        where busy.id <> w.id
          and busy.status = 'processing'
          and busy.lease_until >= now()
          and busy.source_external_user_id is not distinct from w.source_external_user_id
      )
  ), claimable as (
    select w.id
    from private.webhook_inbox w
    join eligible e on e.id = w.id and e.sender_rank = 1
    order by coalesce(nullif(w.payload->>'timestamp','')::bigint, 0), w.received_at, w.id
    for update of w skip locked
    limit p_limit
  ), updated as (
    update private.webhook_inbox w
    set status = 'processing',
        attempts = w.attempts + 1,
        lease_owner = p_worker_id,
        lease_token = gen_random_uuid(),
        lease_until = now() + make_interval(secs => p_lease_seconds),
        last_started_at = now()
    from claimable
    where w.id = claimable.id
    returning w.id, w.provider_event_id, w.source_external_user_id,
              w.payload, w.attempts, w.lease_token
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id,
    'provider_event_id', provider_event_id,
    'source_external_user_id', source_external_user_id,
    'payload', private.fn_line_parser_payload_v1(source_external_user_id, payload),
    'attempts', attempts,
    'lease_token', lease_token
  ) order by attempts), '[]'::jsonb)
  into v_result
  from updated;

  return v_result;
end;
$$;

revoke all on function public.server_tx_claim_webhook_inbox_batch(text, int, int) from public, anon, authenticated;
grant execute on function public.server_tx_claim_webhook_inbox_batch(text, int, int) to service_role;

-- Compatibility shape for the existing process-line-inbox worker.  It is not
-- an unguarded mutation: exactly one live webhook for the sender must exist,
-- the sender was serialized at claim time, and the provider timestamp is
-- passed into the strict 6-argument mutation.  A late/replayed event returns
-- the current draft unchanged instead of falling through as a new command.
create or replace function public.server_tx_update_pending_action(
  p_actor_id uuid,
  p_pending_action_id uuid,
  p_action_type text,
  p_normalized_payload jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pending record;
  v_event_count int;
  v_event_timestamp bigint;
  v_current record;
begin
  select pa.household_id, pa.revision into v_pending
  from private.pending_actions pa
  where pa.id = p_pending_action_id
    and pa.actor_id = p_actor_id
    and pa.source = 'line'
    and pa.status = 'draft'
    and pa.expires_at > now();
  if not found then raise exception 'PENDING_ACTION_NOT_EDITABLE'; end if;

  select count(*), max(nullif(w.payload->>'timestamp','')::bigint)
    into v_event_count, v_event_timestamp
  from private.webhook_inbox w
  join private.line_user_links link
    on link.household_id = v_pending.household_id
   and link.user_id = p_actor_id
   and link.line_user_id = w.source_external_user_id
   and link.status = 'active'
  where w.status = 'processing'
    and w.lease_until >= now();

  if v_event_count <> 1 or v_event_timestamp is null or v_event_timestamp <= 0 then
    raise exception 'LINE_EDIT_EVENT_CONTEXT_INVALID';
  end if;

  begin
    return public.server_tx_update_pending_action(
      p_actor_id, p_pending_action_id, p_action_type, p_normalized_payload,
      v_pending.revision, v_event_timestamp
    );
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'PENDING_ACTION_STALE' then raise; end if;
    select pa.id, pa.action_type, pa.normalized_payload, pa.status, pa.expires_at,
           pa.revision, pa.last_line_event_timestamp
      into v_current
    from private.pending_actions pa
    where pa.id = p_pending_action_id and pa.actor_id = p_actor_id;
    if not found then raise exception 'PENDING_ACTION_NOT_EDITABLE'; end if;
    return jsonb_build_object(
      'id', v_current.id,
      'action_type', v_current.action_type,
      'normalized_payload', v_current.normalized_payload,
      'status', v_current.status,
      'expires_at', v_current.expires_at,
      'revision', v_current.revision,
      'last_line_event_timestamp', v_current.last_line_event_timestamp,
      'stale', true
    );
  end;
end;
$$;

revoke all on function public.server_tx_update_pending_action(uuid, uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.server_tx_update_pending_action(uuid, uuid, text, jsonb)
  to service_role;

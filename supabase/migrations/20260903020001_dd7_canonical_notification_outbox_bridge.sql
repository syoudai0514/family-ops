-- WP-DD7 canonical notification-intent -> existing quota-aware LINE outbox bridge.
--
-- The sender/lease/quota/retry implementation remains unchanged. This migration
-- only decides whether a production user_notification becomes immediately
-- claimable LINE work. Test delivery remains exclusively in test_delivery_outbox
-- because WP-DD3A never creates a production user_notification for test context.

create or replace function private.fn_line_preference_column_for_type(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_type
    -- legacy compatibility
    when 'request_received' then 'request_line'
    when 'request_accepted' then 'request_line'
    when 'request_declined' then 'request_line'
    when 'handover_created' then 'handover_line'
    -- canonical semantic intents
    when 'request.received' then 'request_line'
    when 'request.checking' then 'request_line'
    when 'request.accepted' then 'request_line'
    when 'request.declined' then 'request_line'
    when 'request.cancelled' then 'request_line'
    when 'task.completed_neutral' then 'routine_completion_line'
    else null
  end;
$$;

revoke all on function private.fn_line_preference_column_for_type(text)
  from public, anon, authenticated;
grant execute on function private.fn_line_preference_column_for_type(text) to service_role;

create or replace function private.fn_enqueue_line_notification()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pref_column text;
  v_enabled boolean;
  v_has_link boolean;
  v_existing_id uuid;
  v_item jsonb;
  v_is_canonical boolean;
  v_priority text;
begin
  -- Canonical digest/in-app-only intents are persisted for shared state/history
  -- but do not enter the immediate LINE sender. A later DailyBrief dispatcher
  -- owns digest materialization.
  if coalesce(new.urgency, 'immediate') in ('digest', 'in_app_only') then
    return new;
  end if;

  v_pref_column := private.fn_line_preference_column_for_type(new.type);
  if v_pref_column is null then return new; end if;

  execute format(
    'select %I from public.notification_preferences where household_id = $1 and user_id = $2',
    v_pref_column
  ) into v_enabled using new.household_id, new.recipient_user_id;
  if coalesce(v_enabled, false) is not true then return new; end if;

  select exists (
    select 1 from private.line_user_links
    where user_id = new.recipient_user_id and status = 'active'
  ) into v_has_link;
  if not v_has_link then return new; end if;

  v_item := jsonb_build_object(
    'user_notification_id', new.id,
    'type', new.type,
    'notification_kind', new.notification_kind,
    'title', new.title,
    'body', new.body,
    'dedup_key', new.dedup_key,
    'aggregate_type', new.aggregate_type,
    'aggregate_id', new.aggregate_id,
    'aggregate_revision', new.aggregate_revision
  );

  v_is_canonical := new.notification_kind is not null
    or new.type like 'request.%'
    or new.type = 'task.completed_neutral';
  v_priority := case
    when new.safety_class = 'safety_critical' then 'critical'
    else 'normal'
  end;

  if v_is_canonical then
    -- Canonical urgent coordination is one semantic intent per row. Do not
    -- append it to an unrelated burst bundle: that would obscure its retry /
    -- expiry identity and could delay action-required traffic behind old work.
    insert into private.notification_outbox (
      household_id, recipient_user_id, channel, type, payload, dedup_key,
      priority, business_expires_at, test_context_id
    ) values (
      new.household_id, new.recipient_user_id, 'line', new.type,
      jsonb_build_object('items', jsonb_build_array(v_item)),
      'canonical:' || new.dedup_key,
      v_priority,
      coalesce(new.business_expires_at, now() + interval '24 hours'),
      null
    ) on conflict (recipient_user_id, channel, dedup_key) do nothing;
    return new;
  end if;

  -- Preserve the proven legacy burst-bundling behavior for old notification
  -- types until their aggregate cutover.
  select id into v_existing_id
  from private.notification_outbox
  where household_id = new.household_id
    and recipient_user_id = new.recipient_user_id
    and channel = 'line'
    and status = 'queued'
  order by created_at desc
  limit 1
  for update;

  if found then
    update private.notification_outbox
    set payload = jsonb_set(
          payload, '{items}',
          coalesce(payload -> 'items', '[]'::jsonb) || jsonb_build_array(v_item)
        )
    where id = v_existing_id;
    return new;
  end if;

  insert into private.notification_outbox
    (household_id, recipient_user_id, channel, type, payload, dedup_key,
     priority, business_expires_at, test_context_id)
  values
    (new.household_id, new.recipient_user_id, 'line', new.type,
     jsonb_build_object('items', jsonb_build_array(v_item)),
     'bundle:' || new.dedup_key, 'normal', now() + interval '24 hours', null);

  return new;
end;
$$;

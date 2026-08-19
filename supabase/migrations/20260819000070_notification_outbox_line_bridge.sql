-- WP9 (notification UX / fatigue audit): bridge public.user_notifications
-- (WP2's in-app notification writes: request_received/accepted/declined,
-- handover_created) into private.notification_outbox (the LINE push
-- delivery queue) so send-notifications has real work to drain.
--
-- WP6 built the LINE send loop's *scaffolding* (quota reserve/commit/
-- release/mark_ambiguous in 20260819000009/20260819000015, webhook/
-- pending-action lease queues in 20260819000041/42) but nothing ever
-- inserted into private.notification_outbox for any notification type --
-- confirmed by grep: `insert into private.notification_outbox` does not
-- appear anywhere before this migration (only tests/sql insert test rows
-- directly). Without this bridge, notification_outbox is permanently empty
-- and a fully-correct send-notifications has nothing to send, and WP9's own
-- "message copy audit"/"bundle audit" deliverables would be untestable
-- (see 20260819000025_reassign_task_once.sql's own header comment, which
-- already flagged "notification_outbox do[es] not yet have WP3-owned write
-- paths" as a known gap for a later WP to close).
--
-- docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #7 notification_preferences
-- gates each type: request_line, handover_line (the only two types WP2
-- currently produces). Any future WP-added user_notifications.type not
-- listed in fn_line_preference_column_for_type()'s mapping safely stays
-- in-app-only (no LINE enqueue) until a later migration extends the map --
-- an unmapped type must never break the insert that produced the in-app
-- notification (`return new` is the safe no-op path throughout).
--
-- Bundling (docs/design/v6/06_LINE_INTEGRATION.md #11 "same recipient +
-- same scheduled local minute ... one message"; 15_DDL_CONTRACT.md #320
-- "Bundle may produce one outbox row referenced by multiple ... receipts"):
-- dispatch-routine-automation (WP8, not yet built --
-- 09_API_AND_EDGE_FUNCTIONS.md #7 "insert notification outbox atomically")
-- bundles at INSERT time for its own *scheduled* same-minute sections. This
-- trigger applies the identical "one row, multiple business receipts"
-- principle to *event-driven* WP2 notifications: if the recipient already
-- has a still-`queued` (unclaimed) LINE outbox row, the new item is
-- appended into that row's payload instead of creating a second row -- so a
-- burst of requests/handovers arriving inside one send-notifications
-- polling window becomes one LINE push, not several. Once a row is claimed
-- (status moves off `queued`), a later notification starts a fresh bundle,
-- matching #11's "do not bundle messages separated by time merely to
-- reduce volume".

create or replace function private.fn_line_preference_column_for_type(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'request_received' then 'request_line'
    when 'request_accepted' then 'request_line'
    when 'request_declined' then 'request_line'
    when 'handover_created' then 'handover_line'
    else null
  end;
$$;

revoke all on function private.fn_line_preference_column_for_type(text) from public;
revoke all on function private.fn_line_preference_column_for_type(text) from anon;
revoke all on function private.fn_line_preference_column_for_type(text) from authenticated;
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
begin
  v_pref_column := private.fn_line_preference_column_for_type(new.type);
  if v_pref_column is null then
    return new; -- unmapped type: in-app only, by design (safe default)
  end if;

  -- v_pref_column only ever comes from the fixed CASE mapping above (never
  -- caller/user input), so this dynamic SELECT is not an injection surface.
  execute format(
    'select %I from public.notification_preferences where household_id = $1 and user_id = $2',
    v_pref_column
  ) into v_enabled using new.household_id, new.recipient_user_id;

  if coalesce(v_enabled, false) is not true then
    return new; -- preference row missing or explicitly off
  end if;

  select exists (
    select 1 from private.line_user_links
    where user_id = new.recipient_user_id and status = 'active'
  ) into v_has_link;

  if not v_has_link then
    return new; -- never linked LINE; in-app history (NEW itself) already covers this
  end if;

  v_item := jsonb_build_object(
    'user_notification_id', new.id,
    'type', new.type,
    'title', new.title,
    'body', new.body,
    'dedup_key', new.dedup_key
  );

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
    (household_id, recipient_user_id, channel, type, payload, dedup_key, priority, business_expires_at)
  values
    (new.household_id, new.recipient_user_id, 'line', new.type,
     jsonb_build_object('items', jsonb_build_array(v_item)),
     'bundle:' || new.dedup_key, 'normal', now() + interval '24 hours');

  return new;
end;
$$;

create trigger enqueue_line_notification
  after insert on public.user_notifications
  for each row execute function private.fn_enqueue_line_notification();

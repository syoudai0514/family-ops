-- Preserve LINE sender Flex previews even when the short-lived Reply API
-- token has expired and delivery falls back to the durable push outbox.
create or replace function public.server_tx_enqueue_immediate_line_push(
  p_household_id uuid,
  p_recipient_user_id uuid,
  p_text text,
  p_dedup_key text,
  p_rich_message jsonb
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_dedup text := coalesce(p_dedup_key, 'line-reply-fallback:' || gen_random_uuid()::text);
  v_id uuid;
  v_payload jsonb;
begin
  if p_household_id is null or p_recipient_user_id is null or coalesce(p_text, '') = '' then
    raise exception 'INVALID_INPUT';
  end if;
  if not exists (
    select 1 from public.household_members
    where household_id = p_household_id and user_id = p_recipient_user_id
  ) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;

  v_payload := jsonb_build_object(
    'items', jsonb_build_array(jsonb_build_object('title', p_text)),
    'rich_message', p_rich_message
  );
  insert into private.notification_outbox
    (household_id, recipient_user_id, channel, type, payload, dedup_key, priority, business_expires_at)
  values
    (p_household_id, p_recipient_user_id, 'line', 'line_reply_fallback',
     v_payload, v_dedup, 'normal', now() + interval '1 hour')
  on conflict(recipient_user_id, channel, dedup_key) do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from private.notification_outbox
    where recipient_user_id = p_recipient_user_id and channel = 'line' and dedup_key = v_dedup;
  end if;
  return jsonb_build_object('ok', true, 'notification_outbox_id', v_id);
end;
$$;

revoke all on function public.server_tx_enqueue_immediate_line_push(uuid, uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.server_tx_enqueue_immediate_line_push(uuid, uuid, text, text, jsonb) to service_role;

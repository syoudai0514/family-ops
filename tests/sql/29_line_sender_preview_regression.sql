-- Sender preview fallback remains a Flex message and webhook redelivery
-- keeps exactly one durable outbox row.
\set ON_ERROR_STOP on

insert into auth.users(id) values ('92000000-0000-0000-0000-000000000001');
set role service_role;

do $$
declare
  v_actor uuid := '92000000-0000-0000-0000-000000000001';
  v_hh jsonb;
  v_hh_id uuid;
  v_dedup text := 'line-sender-preview:test-event';
  v_flex jsonb := jsonb_build_object('type', 'flex', 'altText', 'この内容で送りますか？', 'contents', jsonb_build_object('type', 'bubble'));
begin
  v_hh := public.server_tx_create_household(v_actor, gen_random_uuid(), 'LINE preview HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  perform public.server_tx_enqueue_immediate_line_push(v_hh_id, v_actor, 'この内容で送りますか？', v_dedup, v_flex);
  perform public.server_tx_enqueue_immediate_line_push(v_hh_id, v_actor, 'この内容で送りますか？', v_dedup, v_flex);

  if (select count(*) from private.notification_outbox where recipient_user_id = v_actor and dedup_key = v_dedup) <> 1 then
    raise exception 'FAIL line sender preview: redelivery created duplicate fallback rows';
  end if;
  if not exists (
    select 1 from private.notification_outbox
    where recipient_user_id = v_actor and dedup_key = v_dedup
      and payload->'rich_message'->>'type' = 'flex'
      and payload->'rich_message'->>'altText' = 'この内容で送りますか？'
  ) then
    raise exception 'FAIL line sender preview: durable fallback lost Flex payload';
  end if;
end;
$$;

reset role;
select 'line_sender_preview_regression: PASS' as result;

-- Source-document keys are server-minted nursery-r0/<document UUID>, not
-- household/intake filenames. Keep canonical provenance and deletion guards.
-- Legacy filenames are derived from the trusted intake for read-only checks.
create or replace function public.server_read_nursery_line_delivery_context(p_intake_id uuid)
returns jsonb language sql stable security invoker set search_path='' as $$
  select jsonb_build_object(
    'household_id',i.household_id,'received_at',i.received_at,
    'reply_token',w.payload->>'replyToken',
    'object_key',case when i.raw_deleted_at is null and d.raw_deleted_at is null then
      coalesce(d.storage_object_key,i.household_id::text||'/'||i.id::text||'.jpg') else null end,
    'legacy_object_keys',case when i.raw_deleted_at is null and d.raw_deleted_at is null then jsonb_build_array(
      i.household_id::text||'/'||i.id::text||'.jpg',i.household_id::text||'/'||i.id::text||'.png',
      i.household_id::text||'/'||i.id::text||'.webp',i.household_id::text||'/'||i.id::text||'.heic') else '[]'::jsonb end
  ) from private.nursery_line_image_intakes i
  left join private.webhook_inbox w on w.provider_event_id=i.provider_event_id and w.provider='line'
  left join private.source_documents d on d.id=i.source_document_id and d.household_id=i.household_id
  where i.id=p_intake_id;
$$;
revoke all on function public.server_read_nursery_line_delivery_context(uuid) from public,anon,authenticated;
grant execute on function public.server_read_nursery_line_delivery_context(uuid) to service_role;

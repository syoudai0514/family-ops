-- Worker-only context for reply-first delivery and read-only release checks.
-- Neither endpoint is exposed to household clients; no new privileged bypass.
create or replace function public.server_read_nursery_line_delivery_context(p_intake_id uuid)
returns jsonb language sql stable security invoker set search_path='' as $$
  select jsonb_build_object(
    'household_id',i.household_id,'received_at',i.received_at,
    'reply_token',w.payload->>'replyToken','object_key',o.name
  ) from private.nursery_line_image_intakes i
  left join private.webhook_inbox w on w.provider_event_id=i.provider_event_id and w.provider='line'
  left join lateral (
    select storage_object_key as name from private.source_documents where household_id=i.household_id and raw_deleted_at is null
      and storage_object_key in (i.household_id::text||'/'||i.id::text||'.jpg',i.household_id::text||'/'||i.id::text||'.png',
        i.household_id::text||'/'||i.id::text||'.webp',i.household_id::text||'/'||i.id::text||'.heic')
      and i.raw_deleted_at is null order by name limit 1
  ) o on true where i.id=p_intake_id;
$$;
revoke all on function public.server_read_nursery_line_delivery_context(uuid) from public,anon,authenticated;
grant execute on function public.server_read_nursery_line_delivery_context(uuid) to service_role;

-- Apply the same canonical value validators before recording the whole photo.
-- One malformed model candidate must not discard the other valid candidates.
create or replace function public.server_read_validate_nursery_review_items(p_items jsonb)
returns jsonb language plpgsql immutable security invoker set search_path='' as $$
declare v_item jsonb; v_items jsonb:='[]'::jsonb; v_kind text; v_dropped int:=0;
begin
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items)>64 then
    raise exception 'NURSERY_REVIEW_ITEMS_INVALID';
  end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    begin
      v_kind:=v_item->>'item_kind';
      if v_kind is null or v_kind not in ('preparation','task','timetable','shared_info','submission','url','recurrence','exception')
        or coalesce(v_item->>'origin','') not in ('source_explicit','ai_inference')
        or coalesce(v_item->>'confidence_band','') not in ('high','medium','low')
        or coalesce(v_item->>'candidate_key','') !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
        or coalesce(v_item->>'source_locator','') !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$'
        or coalesce((v_item->>'source_page')::int,0) not between 1 and 32
        or octet_length((v_item->'proposed_value')::text)>2048 then raise exception 'NURSERY_REVIEW_ITEM_INVALID'; end if;
      if v_kind='timetable' then
        if coalesce(v_item->>'classification','') not in ('recommended','other') then raise exception 'NURSERY_TIMETABLE_CLASS_REQUIRED'; end if;
      elsif v_item->>'classification' is not null then raise exception 'NURSERY_CLASSIFICATION_INVALID'; end if;
      if v_kind='url' then perform private.fn_validate_nursery_execution_target_review_v1(v_item->'proposed_value');
      else perform private.fn_validate_nursery_review_value_by_kind_v1(v_kind,v_item->'proposed_value'); end if;
      v_items:=v_items||jsonb_build_array(v_item);
    exception when others then v_dropped:=v_dropped+1;
    end;
  end loop;
  return jsonb_build_object('items',v_items,'dropped',v_dropped);
end;
$$;
revoke all on function public.server_read_validate_nursery_review_items(jsonb) from public,anon,authenticated;
grant execute on function public.server_read_validate_nursery_review_items(jsonb) to service_role;

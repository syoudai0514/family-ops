-- Q92/Q96/Q100: human ambiguity resolution, previous-page lookup, and
-- append-only later-notice diff linkage. Confirmed values are never updated in place.

alter table private.nursery_review_items
  add column previous_confirmed_item_id uuid null references public.nursery_confirmed_items(id);

create or replace function private.fn_link_nursery_review_to_previous_v1()
returns trigger language plpgsql security invoker set search_path='' as $$
declare v_context uuid;
begin
  select child_school_context_id into v_context from private.nursery_line_image_intakes where id=new.intake_id and household_id=new.household_id;
  if v_context is not null then
    select c.id into new.previous_confirmed_item_id
    from public.nursery_confirmed_items c
    where c.household_id=new.household_id and c.child_school_context_id=v_context
      and c.item_kind=new.item_kind and c.classification is not distinct from new.classification
    order by c.confirmed_at desc,c.id desc limit 1;
  end if;
  return new;
end $$;
revoke all on function private.fn_link_nursery_review_to_previous_v1() from public,anon,authenticated;
grant execute on function private.fn_link_nursery_review_to_previous_v1() to service_role;
create trigger nursery_review_items_link_previous before insert on private.nursery_review_items
  for each row execute function private.fn_link_nursery_review_to_previous_v1();

create or replace function private.fn_carry_nursery_supersedes_v1()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
  if new.supersedes_confirmed_item_id is null and new.review_item_id is not null then
    select previous_confirmed_item_id into new.supersedes_confirmed_item_id from private.nursery_review_items where id=new.review_item_id;
  end if;
  return new;
end $$;
revoke all on function private.fn_carry_nursery_supersedes_v1() from public,anon,authenticated;
grant execute on function private.fn_carry_nursery_supersedes_v1() to service_role;
create trigger nursery_confirmed_items_carry_supersedes before insert on public.nursery_confirmed_items
  for each row execute function private.fn_carry_nursery_supersedes_v1();

create or replace function public.server_tx_resolve_nursery_ambiguity(
  p_actor_id uuid,p_intake_id uuid,p_expected_revision bigint,p_child_school_context_id uuid,p_resolved_fields text[]
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_i private.nursery_line_image_intakes%rowtype; v_remaining text[];
begin
  select i.* into v_i from private.nursery_line_image_intakes i join public.household_members m on m.household_id=i.household_id
    where i.id=p_intake_id and m.user_id=p_actor_id for update of i;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_i.status not in ('needs_clarification','review_ready') or v_i.revision<>p_expected_revision then raise exception 'NURSERY_INTAKE_STALE'; end if;
  if coalesce(p_resolved_fields,'{}')::text[] <@ array['nursery','child','class','date','document_group']::text[] is not true then raise exception 'NURSERY_AMBIGUITY_INVALID'; end if;
  if p_child_school_context_id is not null and not exists(select 1 from public.child_school_contexts c where c.household_id=v_i.household_id and c.id=p_child_school_context_id) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  select coalesce(array_agg(f),'{}'::text[]) into v_remaining from unnest(v_i.ambiguity_fields) f where not(f=any(coalesce(p_resolved_fields,'{}')));
  update private.nursery_line_image_intakes set child_school_context_id=coalesce(p_child_school_context_id,child_school_context_id),ambiguity_fields=v_remaining,
    status=case when cardinality(v_remaining)=0 and coalesce(p_child_school_context_id,child_school_context_id) is not null then 'review_ready' else 'needs_clarification' end,
    revision=revision+1,updated_at=now() where id=v_i.id returning * into v_i;
  return jsonb_build_object('intake_id',v_i.id,'revision',v_i.revision,'status',v_i.status,'ambiguity_fields',to_jsonb(v_i.ambiguity_fields),'child_school_context_id',v_i.child_school_context_id);
end $$;
revoke all on function public.server_tx_resolve_nursery_ambiguity(uuid,uuid,bigint,uuid,text[]) from public,anon,authenticated;
grant execute on function public.server_tx_resolve_nursery_ambiguity(uuid,uuid,bigint,uuid,text[]) to service_role;

create or replace function public.server_read_pending_nursery_reviews(p_actor_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare v_household uuid; v_rows jsonb;
begin
  select household_id into v_household from public.household_members where user_id=p_actor_id;
  if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('intake_id',i.id,'status',i.status,'revision',i.revision,'received_at',i.received_at,'context_confidence',i.context_confidence,
    'ambiguity_fields',to_jsonb(i.ambiguity_fields),'item_count',(select count(*) from private.nursery_review_items r where r.intake_id=i.id)) order by i.received_at desc),'[]'::jsonb)
  into v_rows from private.nursery_line_image_intakes i where i.household_id=v_household and i.status in ('needs_clarification','review_ready');
  return v_rows;
end $$;
revoke all on function public.server_read_pending_nursery_reviews(uuid) from public,anon,authenticated;
grant execute on function public.server_read_pending_nursery_reviews(uuid) to service_role;

-- Replace review read to include possible nursery/child/class contexts and diff links.
create or replace function public.server_read_nursery_review(p_actor_id uuid,p_intake_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare v_i private.nursery_line_image_intakes%rowtype; v_items jsonb; v_contexts jsonb;
begin
  select i.* into v_i from private.nursery_line_image_intakes i join public.household_members m on m.household_id=i.household_id
    where i.id=p_intake_id and m.user_id=p_actor_id;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'school_display_name',c.school_display_name,'class_display_name',c.class_display_name,'child_display_name',fc.display_name)
    order by c.effective_from desc,c.id),'[]'::jsonb) into v_contexts
  from public.child_school_contexts c join public.family_children fc on fc.household_id=c.household_id and fc.id=c.child_id
  where c.household_id=v_i.household_id and (c.effective_to is null or c.effective_to >= (now() at time zone 'Asia/Tokyo')::date);
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'candidate_key',r.candidate_key,'origin',r.origin,'item_kind',r.item_kind,'classification',r.classification,
    'source_document_id',r.source_document_id,'source_page',r.source_page,'source_locator',r.source_locator,'proposed_value',r.proposed_value,'confidence_band',r.confidence_band,
    'previous_confirmed_item_id',r.previous_confirmed_item_id) order by r.source_page,r.created_at),'[]'::jsonb) into v_items
  from private.nursery_review_items r where r.intake_id=v_i.id;
  return jsonb_build_object('intake_id',v_i.id,'status',v_i.status,'revision',v_i.revision,'child_school_context_id',v_i.child_school_context_id,
    'context_confidence',v_i.context_confidence,'ambiguity_fields',to_jsonb(v_i.ambiguity_fields),'source_document_id',v_i.source_document_id,
    'raw_available',v_i.raw_deleted_at is null and v_i.source_document_id is not null,'available_contexts',v_contexts,'items',v_items);
end $$;
revoke all on function public.server_read_nursery_review(uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_read_nursery_review(uuid,uuid) to service_role;

create or replace function public.server_read_previous_nursery_image(p_current_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare v_i private.nursery_line_image_intakes%rowtype; v_prev private.nursery_line_image_intakes%rowtype;
begin
  select * into v_i from private.nursery_line_image_intakes where id=p_current_id;
  if not found then raise exception 'NURSERY_INTAKE_NOT_FOUND'; end if;
  select * into v_prev from private.nursery_line_image_intakes where household_id=v_i.household_id and line_user_id=v_i.line_user_id and id<>v_i.id and received_at<=v_i.received_at
    and received_at>=v_i.received_at-interval '10 minutes' and status in ('processing','needs_clarification','review_ready','confirmed') order by received_at desc,id desc limit 1;
  if not found then return jsonb_build_object('found',false); end if;
  return jsonb_build_object('found',true,'intake_id',v_prev.id,'received_at',v_prev.received_at,'document_group_id',v_prev.document_group_id,'page_index',v_prev.page_index);
end $$;
revoke all on function public.server_read_previous_nursery_image(uuid) from public,anon,authenticated;
grant execute on function public.server_read_previous_nursery_image(uuid) to service_role;

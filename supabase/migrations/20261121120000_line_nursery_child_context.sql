-- Resolve only the most recent photo from the same linked sender. Old
-- clarification state is kept for review but cannot intercept later chats.
create or replace function public.server_read_line_nursery_child_context(p_actor_id uuid, p_line_user_id text)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  v_intake private.nursery_line_image_intakes%rowtype;
  v_contexts jsonb;
begin
  select i.* into v_intake
  from private.nursery_line_image_intakes i
  join public.household_members m on m.household_id = i.household_id and m.user_id = i.actor_id
  where i.actor_id = p_actor_id and i.line_user_id = p_line_user_id
    and i.received_at >= now() - interval '24 hours'
  order by i.received_at desc, i.id desc limit 1;
  if not found or v_intake.status <> 'needs_clarification'
     or not ('child' = any(v_intake.ambiguity_fields)) then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'name', child.display_name, 'aliases', c.recognition_aliases
  ) order by child.display_name, c.id), '[]'::jsonb) into v_contexts
  from public.child_school_contexts c
  join public.family_children child on child.household_id = c.household_id and child.id = c.child_id
  where c.household_id = v_intake.household_id and c.active and child.active
    and c.effective_from <= (now() at time zone 'Asia/Tokyo')::date
    and (c.effective_to is null or c.effective_to >= (now() at time zone 'Asia/Tokyo')::date);
  return jsonb_build_object('id', v_intake.id, 'revision', v_intake.revision, 'contexts', v_contexts);
end;
$$;
revoke all on function public.server_read_line_nursery_child_context(uuid,text) from public, anon, authenticated;
grant execute on function public.server_read_line_nursery_child_context(uuid,text) to service_role;

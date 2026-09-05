-- Q110-Q112 review UI must show the user the current human-confirmed value next
-- to the Google candidate; do not make a blind accept/keep decision.
create or replace function public.server_read_google_event_reviews(p_actor_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare v_context jsonb; v_household_id uuid; v_result jsonb;
begin
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'revision',r.revision,'candidate_kind',r.candidate_kind,
    'family_event_id',r.family_event_id,
    'family_event_title',e.title,'family_event_all_day',e.all_day,
    'family_event_starts_at',e.starts_at,'family_event_ends_at',e.ends_at,
    'family_event_starts_on',e.starts_on,'family_event_ends_on',e.ends_on,
    'family_event_location_text',e.location_text,
    'google_event_id',r.google_event_id,'google_title',r.google_title,
    'google_status',r.google_status,'google_all_day',r.google_all_day,
    'google_starts_at',r.google_starts_at,'google_ends_at',r.google_ends_at,
    'google_starts_on',r.google_starts_on,'google_ends_on',r.google_ends_on,
    'google_location_text',r.google_location_text,'changed_fields',to_jsonb(r.changed_fields),
    'detected_at',r.created_at
  ) order by r.created_at desc),'[]'::jsonb) into v_result
  from public.google_event_review_candidates r
  join public.family_events e on e.household_id=r.household_id and e.id=r.family_event_id
  where r.household_id=v_household_id and r.status='pending';
  return v_result;
end;
$$;
revoke all on function public.server_read_google_event_reviews(uuid) from public,anon,authenticated;
grant execute on function public.server_read_google_event_reviews(uuid) to service_role;

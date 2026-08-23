-- Prevent duplicate LINE confirmation cards.
--
-- process-line-inbox already sends a Reply-API-first preview for structured
-- task/shopping actions. process-pending-actions should only parse the
-- unresolved needs_pwa_review rows; claiming already structured rows causes
-- the same draft to be previewed a second time through the push outbox.
--
-- Forward-only and safe for production: existing structured drafts already
-- marked previewed remain untouched. The worker still handles all confirmed
-- actions in its separate execution phase.

create or replace function public.server_tx_claim_line_draft_batch(
  p_limit int default 20
) returns table(
  id uuid,
  household_id uuid,
  actor_id uuid,
  action_type text,
  normalized_payload jsonb
)
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'INVALID_INPUT';
  end if;

  return query
  with candidates as (
    select pa.id
    from private.pending_actions pa
    where pa.source = 'line'
      and pa.status = 'draft'
      and pa.expires_at > now()
      and pa.action_type = 'needs_pwa_review'
      and (
        coalesce(pa.normalized_payload->>'line_intent_state','') in ('','ready_preview')
        or (
          pa.normalized_payload->>'line_intent_state' = 'processing'
          and coalesce(
            (pa.normalized_payload->>'line_intent_claimed_at')::timestamptz,
            '-infinity'::timestamptz
          ) < now() - interval '2 minutes'
        )
      )
    order by pa.created_at
    for update skip locked
    limit p_limit
  ), claimed as (
    update private.pending_actions pa
    set normalized_payload = jsonb_set(
          jsonb_set(pa.normalized_payload, '{line_intent_state}', '"processing"'::jsonb, true),
          '{line_intent_claimed_at}', to_jsonb(now()::text), true
        ),
        updated_at = now()
    from candidates c
    where pa.id = c.id
    returning pa.id, pa.household_id, pa.actor_id, pa.action_type, pa.normalized_payload
  )
  select claimed.id, claimed.household_id, claimed.actor_id, claimed.action_type, claimed.normalized_payload
  from claimed;
end;
$$;

revoke all on function public.server_tx_claim_line_draft_batch(int)
  from public, anon, authenticated;
grant execute on function public.server_tx_claim_line_draft_batch(int)
  to service_role;

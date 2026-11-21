-- Retain a bounded machine code only; never persist photo or provider text.
alter table private.nursery_line_image_intakes
  add column if not exists last_error text
  check (last_error is null or last_error ~ '^[A-Z0-9_]{1,101}$');

create or replace function public.server_tx_fail_nursery_line_image(p_intake_id uuid, p_expected_revision bigint, p_error_code text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb;
begin
  if p_error_code is null or p_error_code !~ '^[A-Z0-9_]{1,101}$' then raise exception 'INVALID_INPUT'; end if;
  result := public.server_tx_finish_nursery_image_review(
    p_intake_id,p_expected_revision,'failed',null,null,null,null,'{}'::text[],'[]'::jsonb,false
  );
  update private.nursery_line_image_intakes set last_error=p_error_code
    where id=p_intake_id and revision=(result->>'revision')::bigint and status='failed';
  return result;
end;
$$;

create or replace function public.server_read_previous_nursery_failure(p_intake_id uuid)
returns boolean language sql stable security invoker set search_path='' as $$
  select coalesce((
    select previous.status = 'failed'
    from private.nursery_line_image_intakes current_image
    join private.nursery_line_image_intakes previous
      on previous.household_id=current_image.household_id
      and previous.actor_id=current_image.actor_id and previous.line_user_id=current_image.line_user_id
      and (previous.received_at, previous.id) < (current_image.received_at, current_image.id)
      and previous.received_at >= current_image.received_at - interval '24 hours'
    where current_image.id=p_intake_id
    order by previous.received_at desc, previous.id desc limit 1
  ), false);
$$;
revoke all on function public.server_tx_fail_nursery_line_image(uuid,bigint,text) from public,anon,authenticated;
revoke all on function public.server_read_previous_nursery_failure(uuid) from public,anon,authenticated;
grant execute on function public.server_tx_fail_nursery_line_image(uuid,bigint,text) to service_role;
grant execute on function public.server_read_previous_nursery_failure(uuid) to service_role;

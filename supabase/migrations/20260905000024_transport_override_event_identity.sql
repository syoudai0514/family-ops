-- A transport occurrence override is not the same semantic event as the
-- existing explicit one-off reassignment agreement. The template saver protects
-- genuine `reassigned_once` events. If override application reused that event
-- type, deleting the override would still make the occurrence permanently look
-- protected and later templates could no longer apply. Normalize only the
-- transport-tagged event at the table boundary; normal reassigned_once history
-- remains untouched.

create or replace function private.fn_normalize_transport_override_task_event_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.event_type='reassigned_once'
     and new.payload ? 'transport_override_id' then
    new.event_type := 'transport_override_applied';
  end if;
  return new;
end;
$$;

revoke all on function private.fn_normalize_transport_override_task_event_v1() from public,anon,authenticated;
grant execute on function private.fn_normalize_transport_override_task_event_v1() to service_role;

drop trigger if exists task_events_normalize_transport_override_v1 on public.task_events;
create trigger task_events_normalize_transport_override_v1
before insert on public.task_events
for each row execute function private.fn_normalize_transport_override_task_event_v1();

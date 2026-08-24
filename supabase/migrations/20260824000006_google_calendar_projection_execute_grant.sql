-- Allow the service-role-only calendar target mutation to invoke the private
-- projection enqueue helper. Keep direct execution unavailable to client roles.

revoke execute on function private.enqueue_family_ops_calendar_projection(uuid, uuid, date, uuid) from public;
revoke execute on function private.enqueue_family_ops_calendar_projection(uuid, uuid, date, uuid) from anon;
revoke execute on function private.enqueue_family_ops_calendar_projection(uuid, uuid, date, uuid) from authenticated;
grant execute on function private.enqueue_family_ops_calendar_projection(uuid, uuid, date, uuid) to service_role;

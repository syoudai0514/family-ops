-- server_tx_replace_routine_subtasks is SECURITY INVOKER and executes this
-- private predicate while running as service_role. Keep the predicate private
-- to application roles, but grant that internal worker role explicitly.
grant execute on function private.is_custom_routine_definition(text,text) to service_role;

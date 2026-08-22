-- Trigger helpers are internal implementation details and must never be
-- executable by browser roles (or PUBLIC via PostgreSQL's default grant).
revoke all on function private.fn_enrich_line_outbox_request_payload() from public, anon, authenticated;
grant execute on function private.fn_enrich_line_outbox_request_payload() to service_role;

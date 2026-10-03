-- The LINE understanding model is a setting: null = environment, a valid Gemini id
-- overrides it, anything else is refused. Only the service role can read it.
\set ON_ERROR_STOP on

begin;
set role service_role;

do $$
declare
  failed boolean;
begin
  update private.line_ai_settings set understand_model = null where id;
  if public.server_read_line_understand_model() is not null then
    raise exception 'FAIL model setting: null must read as null (the environment decides)';
  end if;

  update private.line_ai_settings set understand_model = 'gemini-3.5-flash' where id;
  if public.server_read_line_understand_model() <> 'gemini-3.5-flash' then
    raise exception 'FAIL model setting: a valid id must be returned';
  end if;

  failed := false;
  begin
    update private.line_ai_settings set understand_model = 'gemini-3.5-flash:generateContent?key=x' where id;
  exception when check_violation then failed := true; end;
  if not failed then raise exception 'FAIL model setting: a malformed id must be refused'; end if;
end $$;

reset role;
set role authenticated;
do $$
begin
  perform public.server_read_line_understand_model();
  raise exception 'FAIL model setting: authenticated must not read the setting';
exception when insufficient_privilege then null;
end $$;
reset role;

rollback;

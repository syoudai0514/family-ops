\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare first jsonb; second jsonb;
begin
 if public.server_tx_web_push_vapid_keys(null,null) is not null then raise exception 'FAIL read must not create keys'; end if;
 first:=public.server_tx_web_push_vapid_keys('B'||repeat('a',86),repeat('p',43));
 second:=public.server_tx_web_push_vapid_keys('B'||repeat('z',86),repeat('q',43));
 if first<>second or first->>'public_key'<>'B'||repeat('a',86) then raise exception 'FAIL the first pair must win: % %',first,second; end if;
 if has_function_privilege('authenticated','public.server_tx_web_push_vapid_keys(text,text)','execute') then
   raise exception 'FAIL keys exposed to clients'; end if;
end $$;
reset role;
rollback;
select 'web_push_vapid_keys: PASS' as result;
